import Foundation
import os.log

extension ConnectionSessionManager {
    // MARK: - Terminal I/O Request Lifecycle

    func waitForInputRequest(_ requestID: UUID) async {
        await inputRequestStore[requestID]?.task.value
    }

    func waitForSessionRichPasteUploadRequest(_ requestID: UUID) async {
        await richPasteUploadRequestStore[requestID]?.task.value
    }

    func waitForResizeRequest(_ requestID: UUID) async {
        await resizeRequestStore[requestID]?.task.value
    }

    func cancelInputRequests(for sessionId: UUID) {
        inputRequestStore.removeAllRequests(forScope: sessionId).forEach { $0.task.cancel() }
    }

    func cancelSessionRichPasteUploadRequests(for sessionId: UUID) -> [Task<Void, Never>] {
        let requests = richPasteUploadRequestStore.removeAllRequests(forScope: sessionId)
        requests.forEach { $0.task.cancel() }
        return requests.map(\.task)
    }

    func cancelResizeRequests(for sessionId: UUID) {
        resizeRequestStore.removeMappedRequest(forScope: sessionId)?.task.cancel()
    }

    func sendInput(_ data: Data, to sessionId: UUID) async {
        if let runtime = terminalConnectionRegistry.runtime(for: .session(sessionId)) {
            do {
                try await runtime.send(data)
                return
            } catch SSHError.notConnected {
                // Input can arrive before shell registration; fallback routes
                // below handle existing registered shells without noisy logs.
            } catch {
                logger.error("Failed to send to SSH: \(error.localizedDescription)")
            }
        }

        guard let runtime = sessionRuntimes[sessionId] else {
            if let route = registeredShellRoute(for: sessionId) {
                try? await route.client.write(data, to: route.shellId)
            }
            return
        }

        if let shellId = await runtime.runtime.currentShellId(),
           let client = await runtime.runtime.runnerClientIfCreated() {
            do {
                try await client.write(data, to: shellId)
            } catch {
                logger.error("Failed to send to SSH: \(error.localizedDescription)")
            }
            return
        }

        if let route = registeredShellRoute(for: sessionId) {
            do {
                try await route.client.write(data, to: route.shellId)
            } catch {
                logger.error("Failed to send to SSH: \(error.localizedDescription)")
            }
        }
    }

    @discardableResult
    func requestSessionInput(_ data: Data, to sessionId: UUID) -> UUID? {
        guard !data.isEmpty else { return nil }
        guard sessionWithID(sessionId) != nil else { return nil }

        let requestID = UUID()
        let previousTask = inputRequestStore.lastTask(forScope: sessionId)
        let task = Task { @MainActor [weak self] in
            if let previousTask {
                await previousTask.value
            }

            guard let self else { return }
            defer {
                self.inputRequestStore.remove(id: requestID, ifLatestForScope: sessionId)
            }

            guard !Task.isCancelled else { return }
            guard self.sessionWithID(sessionId) != nil else { return }

            #if DEBUG
            if let inputOperationForTesting = self.inputOperationForTesting {
                await inputOperationForTesting(data, .session(sessionId))
                return
            }
            #endif

            await self.sendInput(data, to: sessionId)
        }

        inputRequestStore.insert(
            InputRequest(sessionId: sessionId, task: task),
            id: requestID,
            scopeID: sessionId,
            task: task
        )
        return requestID
    }

    @discardableResult
    func requestSessionRichPasteUpload(
        image: ClipboardImagePayload,
        settings: RichClipboardSettings,
        for sessionId: UUID,
        onProgress: @escaping @MainActor (String?) -> Void = { _ in },
        onCompleted: @escaping @MainActor (TerminalRichPasteUploadRequestResult) -> Void = { _ in }
    ) -> UUID? {
        guard sessionWithID(sessionId) != nil else { return nil }

        if let previousRequestID = richPasteUploadRequestStore.requestID(forScope: sessionId) {
            richPasteUploadRequestStore[previousRequestID]?.task.cancel()
        }

        let requestID = UUID()
        let upload = richPasteUploadOperation(for: sessionId)
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.richPasteUploadRequestStore.remove(id: requestID, ifMappedTo: sessionId)
            }

            guard !Task.isCancelled else {
                onCompleted(.cancelled)
                return
            }
            guard self.sessionWithID(sessionId) != nil else {
                onCompleted(.cancelled)
                return
            }

            let result = await TerminalRichPasteUploadRequest.perform(
                image: image,
                settings: settings,
                lease: self.richPasteLease(for: sessionId),
                upload: upload,
                onProgress: { message in
                    guard self.richPasteUploadRequestStore.requestID(forScope: sessionId) == requestID else { return }
                    onProgress(message)
                },
                pasteUploadedPath: { [weak self] text in
                    guard let self else { return }
                    guard self.sessionWithID(sessionId) != nil else { return }
                    guard let inputRequestID = self.requestSessionInput(
                        Data(text.utf8),
                        to: sessionId
                    ) else {
                        return
                    }
                    await self.waitForInputRequest(inputRequestID)
                }
            )

            if Task.isCancelled {
                onCompleted(.cancelled)
                return
            }
            onCompleted(result)
        }

        richPasteUploadRequestStore.insert(
            RichPasteUploadRequest(
                sessionId: sessionId,
                task: task
            ),
            id: requestID,
            scopeID: sessionId
        )
        return requestID
    }

    func resizeSession(_ sessionId: UUID, cols: Int, rows: Int) async {
        guard cols > 0 && rows > 0 else { return }

        if let runtime = terminalConnectionRegistry.runtime(for: .session(sessionId)) {
            do {
                try await runtime.resize(cols: cols, rows: rows)
                return
            } catch SSHError.notConnected {
                // The first resize often arrives before the remote shell exists.
            } catch {
                logger.warning("Failed to resize PTY: \(error.localizedDescription)")
            }
        }

        if let runtime = sessionRuntimes[sessionId] {
            if let shellId = await runtime.runtime.currentShellId(),
               let client = await runtime.runtime.runnerClientIfCreated() {
                do {
                    try await client.resize(cols: cols, rows: rows, for: shellId)
                } catch {
                    logger.warning("Failed to resize PTY: \(error.localizedDescription)")
                }
                return
            }
        }

        guard let route = registeredShellRoute(for: sessionId) else { return }
        do {
            try await route.client.resize(cols: cols, rows: rows, for: route.shellId)
        } catch {
            logger.warning("Failed to resize PTY: \(error.localizedDescription)")
        }
    }

    @discardableResult
    func requestSessionResize(_ size: TerminalResizeRequestSize, for sessionId: UUID) -> UUID? {
        guard size.isValid else { return nil }
        guard sessionWithID(sessionId) != nil else { return nil }

        if let existingRequestID = resizeRequestStore.requestID(forScope: sessionId) {
            resizeRequestStore.update(existingRequestID) { $0.size = size }
            return existingRequestID
        }

        let requestID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.resizeRequestStore.remove(id: requestID, ifMappedTo: sessionId)
            }

            var appliedSize: TerminalResizeRequestSize?
            while !Task.isCancelled {
                guard self.sessionWithID(sessionId) != nil else { return }
                guard let request = self.resizeRequestStore[requestID] else { return }
                let size = request.size
                guard size != appliedSize else { return }

                #if DEBUG
                if let resizeOperationForTesting = self.resizeOperationForTesting {
                    await resizeOperationForTesting(size, .session(sessionId))
                } else {
                    await self.resizeSession(sessionId, cols: size.cols, rows: size.rows)
                }
                #else
                await self.resizeSession(sessionId, cols: size.cols, rows: size.rows)
                #endif

                appliedSize = size
            }
        }

        resizeRequestStore.insert(
            ResizeRequest(sessionId: sessionId, size: size, task: task),
            id: requestID,
            scopeID: sessionId
        )
        return requestID
    }

    private func richPasteLease(for sessionId: UUID) -> RemoteConnectionLease? {
        #if DEBUG
        if let richPasteLeaseProviderForTesting {
            return richPasteLeaseProviderForTesting(sessionId)
        }
        #endif

        return remoteConnectionLease(forSessionId: sessionId)
    }

    private func richPasteUploadOperation(for sessionId: UUID) -> TerminalRichPasteUploadOperation {
        #if DEBUG
        if let richPasteUploadOperationForTesting {
            return richPasteUploadOperationForTesting
        }
        #endif

        let coordinator = TerminalRichPasteCoordinator(sessionId: sessionId)
        return { image, settings, client, _ in
            try await coordinator.performRichPaste(
                image: image,
                settings: settings,
                client: client
            )
        }
    }
}
