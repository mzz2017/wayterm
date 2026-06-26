import Foundation
import os.log

extension TerminalTabManager {
    // MARK: - Pane Terminal I/O Request Lifecycle

    func waitForInputRequest(_ requestID: UUID) async {
        await inputRequestStore[requestID]?.task.value
    }

    func waitForPaneRichPasteUploadRequest(_ requestID: UUID) async {
        await richPasteUploadRequestStore[requestID]?.task.value
    }

    func waitForResizeRequest(_ requestID: UUID) async {
        await resizeRequestStore[requestID]?.task.value
    }

    func cancelInputRequests(for paneId: UUID) {
        inputRequestStore.removeAllRequests(forScope: paneId).forEach { $0.task.cancel() }
    }

    func cancelPaneRichPasteUploadRequests(for paneId: UUID) -> [Task<Void, Never>] {
        let requests = richPasteUploadRequestStore.removeAllRequests(forScope: paneId)
        requests.forEach { $0.task.cancel() }
        return requests.map(\.task)
    }

    func cancelResizeRequests(for paneId: UUID) {
        resizeRequestStore.removeMappedRequest(forScope: paneId)?.task.cancel()
    }

    func sendInput(_ data: Data, toPane paneId: UUID) async {
        if let runtime = terminalConnectionRegistry.runtime(for: .pane(paneId)) {
            do {
                try await runtime.send(data)
                return
            } catch SSHError.notConnected {
                // Input can arrive before shell registration; fallback routes
                // below handle existing registered shells without noisy logs.
            } catch {
                logger.error("Failed to send to pane SSH: \(error.localizedDescription)")
            }
        }

        guard let runtime = paneRuntimes[paneId] else {
            if let route = registeredShellRoute(forPane: paneId) {
                try? await route.client.write(data, to: route.shellId)
            }
            return
        }

        if let shellId = await runtime.runtime.currentShellId(),
           let client = await runtime.runtime.runnerClientIfCreated() {
            do {
                try await client.write(data, to: shellId)
            } catch {
                logger.error("Failed to send to pane SSH: \(error.localizedDescription)")
            }
            return
        }

        if let route = registeredShellRoute(forPane: paneId) {
            do {
                try await route.client.write(data, to: route.shellId)
            } catch {
                logger.error("Failed to send to pane SSH: \(error.localizedDescription)")
            }
        }
    }

    @discardableResult
    func requestPaneInput(_ data: Data, toPane paneId: UUID) -> UUID? {
        guard !data.isEmpty else { return nil }
        guard paneStates[paneId] != nil else { return nil }

        let requestID = UUID()
        let previousTask = inputRequestStore.lastTask(forScope: paneId)
        let task = Task { @MainActor [weak self] in
            if let previousTask {
                await previousTask.value
            }

            guard let self else { return }
            defer {
                self.inputRequestStore.remove(id: requestID, ifLatestForScope: paneId)
            }

            guard !Task.isCancelled else { return }
            guard self.paneStates[paneId] != nil else { return }

            #if DEBUG
            if let inputOperationForTesting = self.inputOperationForTesting {
                await inputOperationForTesting(data, .pane(paneId))
                return
            }
            #endif

            await self.sendInput(data, toPane: paneId)
        }

        inputRequestStore.insert(
            InputRequest(paneId: paneId, task: task),
            id: requestID,
            scopeID: paneId,
            task: task
        )
        return requestID
    }

    @discardableResult
    func requestPaneRichPasteUpload(
        image: ClipboardImagePayload,
        settings: RichClipboardSettings,
        forPane paneId: UUID,
        onProgress: @escaping @MainActor (String?) -> Void = { _ in },
        onCompleted: @escaping @MainActor (TerminalRichPasteUploadRequestResult) -> Void = { _ in }
    ) -> UUID? {
        guard paneStates[paneId] != nil else { return nil }

        if let previousRequestID = richPasteUploadRequestStore.requestID(forScope: paneId) {
            richPasteUploadRequestStore[previousRequestID]?.task.cancel()
        }

        let requestID = UUID()
        let upload = richPasteUploadOperation(for: paneId)
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.richPasteUploadRequestStore.remove(id: requestID, ifMappedTo: paneId)
            }

            guard !Task.isCancelled else {
                onCompleted(.cancelled)
                return
            }
            guard self.paneStates[paneId] != nil else {
                onCompleted(.cancelled)
                return
            }

            let result = await TerminalRichPasteUploadRequest.perform(
                image: image,
                settings: settings,
                lease: self.richPasteLease(for: paneId),
                upload: upload,
                onProgress: { message in
                    guard self.richPasteUploadRequestStore.requestID(forScope: paneId) == requestID else { return }
                    onProgress(message)
                },
                pasteUploadedPath: { [weak self] text in
                    guard let self else { return }
                    guard self.paneStates[paneId] != nil else { return }
                    guard let inputRequestID = self.requestPaneInput(
                        Data(text.utf8),
                        toPane: paneId
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
                paneId: paneId,
                task: task
            ),
            id: requestID,
            scopeID: paneId
        )
        return requestID
    }

    func resizePane(_ paneId: UUID, cols: Int, rows: Int) async {
        guard cols > 0 && rows > 0 else { return }

        if let runtime = terminalConnectionRegistry.runtime(for: .pane(paneId)) {
            do {
                try await runtime.resize(cols: cols, rows: rows)
                return
            } catch SSHError.notConnected {
                // The first resize often arrives before the remote shell exists.
            } catch {
                logger.warning("Failed to resize pane PTY: \(error.localizedDescription)")
            }
        }

        if let runtime = paneRuntimes[paneId] {
            if let shellId = await runtime.runtime.currentShellId(),
               let client = await runtime.runtime.runnerClientIfCreated() {
                do {
                    try await client.resize(cols: cols, rows: rows, for: shellId)
                } catch {
                    logger.warning("Failed to resize pane PTY: \(error.localizedDescription)")
                }
                return
            }
        }

        guard let route = registeredShellRoute(forPane: paneId) else { return }
        do {
            try await route.client.resize(cols: cols, rows: rows, for: route.shellId)
        } catch {
            logger.warning("Failed to resize pane PTY: \(error.localizedDescription)")
        }
    }

    @discardableResult
    func requestPaneResize(_ size: TerminalResizeRequestSize, forPane paneId: UUID) -> UUID? {
        guard size.isValid else { return nil }
        guard paneStates[paneId] != nil else { return nil }

        if let existingRequestID = resizeRequestStore.requestID(forScope: paneId) {
            resizeRequestStore.update(existingRequestID) { $0.size = size }
            return existingRequestID
        }

        let requestID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.resizeRequestStore.remove(id: requestID, ifMappedTo: paneId)
            }

            var appliedSize: TerminalResizeRequestSize?
            while !Task.isCancelled {
                guard self.paneStates[paneId] != nil else { return }
                guard let request = self.resizeRequestStore[requestID] else { return }
                let size = request.size
                guard size != appliedSize else { return }

                #if DEBUG
                if let resizeOperationForTesting = self.resizeOperationForTesting {
                    await resizeOperationForTesting(size, .pane(paneId))
                } else {
                    await self.resizePane(paneId, cols: size.cols, rows: size.rows)
                }
                #else
                await self.resizePane(paneId, cols: size.cols, rows: size.rows)
                #endif

                appliedSize = size
            }
        }

        resizeRequestStore.insert(
            ResizeRequest(paneId: paneId, size: size, task: task),
            id: requestID,
            scopeID: paneId
        )
        return requestID
    }

    private func richPasteLease(for paneId: UUID) -> RemoteConnectionLease? {
        #if DEBUG
        if let richPasteLeaseProviderForTesting {
            return richPasteLeaseProviderForTesting(paneId)
        }
        #endif

        return remoteConnectionLease(for: paneId)
    }

    private func richPasteUploadOperation(for paneId: UUID) -> TerminalRichPasteUploadOperation {
        #if DEBUG
        if let richPasteUploadOperationForTesting {
            return richPasteUploadOperationForTesting
        }
        #endif

        let coordinator = TerminalRichPasteCoordinator(sessionId: paneId)
        return { image, settings, client, _ in
            try await coordinator.performRichPaste(
                image: image,
                settings: settings,
                client: client
            )
        }
    }
}
