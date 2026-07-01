import Foundation

extension TerminalTabManager {
    func reconnectPane(_ paneId: UUID) async {
        guard let paneState = paneStates[paneId] else { return }
        await waitForServerTeardownTasks(paneState.serverId)
        if terminalConnectionRegistry.isOpeningOrStreaming(.pane(paneId)) {
            return
        }

        updatePaneState(paneId, connectionState: .reconnecting(attempt: 1))
        await unregisterSSHClient(for: paneId)
        await clearRuntimeShellForReconnect(paneId: paneId)
    }

    func retryPaneConnection(
        paneId: UUID,
        server: Server
    ) async -> TerminalReconnectRequestResult {
        guard shouldManuallyReconnectPane(
            paneId,
            reconnectInFlight: reconnectInFlightStore.contains(paneId)
        ) else {
            return .skipped
        }
        guard reconnectInFlightStore.begin(paneId) else {
            return .skipped
        }

        defer { reconnectInFlightStore.finish(paneId) }

        do {
            let credentials = try await credentialsProvider(server)
            guard canStartPaneReconnect(paneId) else {
                return .skipped
            }
            await reconnectPane(paneId)
            return .started(credentials)
        } catch {
            return .credentialLoadFailed(error.localizedDescription)
        }
    }

    @discardableResult
    func requestPaneRetry(
        paneId: UUID,
        server: Server,
        onCompleted: @escaping @MainActor (TerminalReconnectRequestResult) -> Void = { _ in }
    ) -> UUID {
        if let requestID = paneRetryRequestStore.requestID(forScope: paneId) {
            paneRetryRequestStore.update(requestID) { $0.onCompleted.append(onCompleted) }
            return requestID
        }

        let requestID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.paneRetryRequestStore.remove(id: requestID, ifMappedTo: paneId)
            }

            #if DEBUG
            let result: TerminalReconnectRequestResult
            if let operation = self.paneRetryOperationForTesting {
                result = await operation(paneId, server)
            } else {
                result = await self.retryPaneConnection(paneId: paneId, server: server)
            }
            #else
            let result = await self.retryPaneConnection(paneId: paneId, server: server)
            #endif

            let callbacks = self.paneRetryRequestStore
                .remove(id: requestID, ifMappedTo: paneId)?
                .onCompleted ?? []
            callbacks.forEach { $0(Task.isCancelled ? .skipped : result) }
        }
        paneRetryRequestStore.insert(
            PaneRetryRequest(
                paneId: paneId,
                task: task,
                onCompleted: [onCompleted]
            ),
            id: requestID,
            scopeID: paneId
        )
        return requestID
    }

    func waitForPaneRetryRequest(_ requestID: UUID) async {
        await paneRetryRequestStore[requestID]?.task.value
    }

    func loadCredentials(for server: Server) async -> TerminalCredentialLoadResult {
        do {
            return .loaded(try await credentialsProvider(server))
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    @discardableResult
    func requestPaneCredentialLoad(
        paneId: UUID,
        server: Server,
        onCompleted: @escaping @MainActor (TerminalCredentialLoadResult) -> Void = { _ in }
    ) -> UUID {
        if let requestID = paneCredentialLoadRequestStore.requestID(forScope: paneId) {
            paneCredentialLoadRequestStore.update(requestID) { $0.onCompleted.append(onCompleted) }
            return requestID
        }

        let requestID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.paneCredentialLoadRequestStore.remove(id: requestID, ifMappedTo: paneId)
            }

            guard self.canRunPaneCredentialLoad(paneId: paneId, server: server) else { return }
            let result = await self.loadCredentials(for: server)
            guard self.canRunPaneCredentialLoad(paneId: paneId, server: server) else { return }

            let callbacks = self.paneCredentialLoadRequestStore
                .remove(id: requestID, ifMappedTo: paneId)?
                .onCompleted ?? []
            callbacks.forEach { $0(result) }
        }
        paneCredentialLoadRequestStore.insert(
            PaneCredentialLoadRequest(
                paneId: paneId,
                task: task,
                onCompleted: [onCompleted]
            ),
            id: requestID,
            scopeID: paneId
        )
        return requestID
    }

    func waitForPaneCredentialLoadRequest(_ requestID: UUID) async {
        await paneCredentialLoadRequestStore[requestID]?.task.value
    }

    func retrustHostAndReconnect(paneId: UUID, server: Server) async -> Bool {
        guard canRunPaneHostRetrust(paneId: paneId, server: server) else { return false }
        await knownHostTrustApprover(server.host, server.port)
        guard canRunPaneHostRetrust(paneId: paneId, server: server) else { return false }
        await reconnectPane(paneId)
        return true
    }

    @discardableResult
    func requestPaneHostRetrust(
        paneId: UUID,
        server: Server,
        onCompleted: @escaping @MainActor (Bool) -> Void = { _ in }
    ) -> UUID {
        if let requestID = paneHostRetrustRequestStore.requestID(forScope: paneId) {
            paneHostRetrustRequestStore.update(requestID) { $0.onCompleted.append(onCompleted) }
            return requestID
        }

        let requestID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.paneHostRetrustRequestStore.remove(id: requestID, ifMappedTo: paneId)
            }

            guard self.canRunPaneHostRetrust(paneId: paneId, server: server) else {
                let callbacks = self.paneHostRetrustRequestStore
                    .remove(id: requestID, ifMappedTo: paneId)?
                    .onCompleted ?? []
                callbacks.forEach { $0(false) }
                return
            }

            #if DEBUG
            let didReconnect: Bool
            if let operation = self.paneHostRetrustOperationForTesting {
                didReconnect = await operation(paneId, server)
            } else {
                didReconnect = await self.retrustHostAndReconnect(paneId: paneId, server: server)
            }
            #else
            let didReconnect = await self.retrustHostAndReconnect(paneId: paneId, server: server)
            #endif

            let callbacks = self.paneHostRetrustRequestStore
                .remove(id: requestID, ifMappedTo: paneId)?
                .onCompleted ?? []
            callbacks.forEach {
                $0(self.canRunPaneHostRetrust(paneId: paneId, server: server) ? didReconnect : false)
            }
        }
        paneHostRetrustRequestStore.insert(
            PaneHostRetrustRequest(
                paneId: paneId,
                task: task,
                onCompleted: [onCompleted]
            ),
            id: requestID,
            scopeID: paneId
        )
        return requestID
    }

    func waitForPaneHostRetrustRequest(_ requestID: UUID) async {
        await paneHostRetrustRequestStore[requestID]?.task.value
    }

    func installMoshServerAndReconnect(for paneId: UUID) async throws {
        try await installMoshServer(for: paneId)
        await reconnectPane(paneId)
    }

    @discardableResult
    func requestTmuxInstall(
        for paneId: UUID,
        onCompleted: @escaping @MainActor () -> Void = {}
    ) -> UUID {
        if let requestID = tmuxInstallRequestStore.requestID(forScope: paneId) {
            tmuxInstallRequestStore.update(requestID) { $0.onCompleted.append(onCompleted) }
            return requestID
        }

        let requestID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.tmuxInstallRequestStore.remove(id: requestID, ifMappedTo: paneId)
            }

            #if DEBUG
            if let operation = self.tmuxInstallOperationForTesting {
                await operation(paneId)
            } else {
                await self.startTmuxInstall(for: paneId)
            }
            #else
            await self.startTmuxInstall(for: paneId)
            #endif

            guard !Task.isCancelled else { return }
            let callbacks = self.tmuxInstallRequestStore
                .remove(id: requestID, ifMappedTo: paneId)?
                .onCompleted ?? []
            callbacks.forEach { $0() }
        }
        tmuxInstallRequestStore.insert(
            TmuxInstallRequest(
                paneId: paneId,
                task: task,
                onCompleted: [onCompleted]
            ),
            id: requestID,
            scopeID: paneId
        )
        return requestID
    }

    func waitForTmuxInstallRequest(_ requestID: UUID) async {
        await tmuxInstallRequestStore[requestID]?.task.value
    }

    @discardableResult
    func requestMoshInstallAndReconnect(
        for paneId: UUID,
        onCompleted: @escaping @MainActor () -> Void = {},
        onFailed: @escaping @MainActor (Error) -> Void = { _ in }
    ) -> UUID {
        if let requestID = moshInstallRequestStore.requestID(forScope: paneId) {
            moshInstallRequestStore.update(requestID) {
                $0.onCompleted.append(onCompleted)
                $0.onFailed.append(onFailed)
            }
            return requestID
        }

        setLastMoshInstallFailure(nil)
        let requestID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.moshInstallRequestStore.remove(id: requestID, ifMappedTo: paneId)
            }

            do {
                #if DEBUG
                if let operation = self.moshInstallAndReconnectOperationForTesting {
                    try await operation(paneId)
                } else {
                    try await self.installMoshServerAndReconnect(for: paneId)
                }
                #else
                try await self.installMoshServerAndReconnect(for: paneId)
                #endif

                guard !Task.isCancelled else { return }
                let callbacks = self.moshInstallRequestStore
                    .remove(id: requestID, ifMappedTo: paneId)?
                    .onCompleted ?? []
                callbacks.forEach { $0() }
            } catch is CancellationError {
                let callbacks = self.moshInstallRequestStore
                    .remove(id: requestID, ifMappedTo: paneId)?
                    .onCompleted ?? []
                callbacks.forEach { $0() }
                return
            } catch {
                self.setLastMoshInstallFailure(error)
                let callbacks = self.moshInstallRequestStore
                    .remove(id: requestID, ifMappedTo: paneId)?
                    .onFailed ?? []
                callbacks.forEach { $0(error) }
            }
        }
        moshInstallRequestStore.insert(
            MoshInstallRequest(
                paneId: paneId,
                task: task,
                onCompleted: [onCompleted],
                onFailed: [onFailed]
            ),
            id: requestID,
            scopeID: paneId
        )
        return requestID
    }

    func waitForMoshInstallRequest(_ requestID: UUID) async {
        await moshInstallRequestStore[requestID]?.task.value
    }

    private func canStartPaneReconnect(_ paneId: UUID) -> Bool {
        guard let state = paneStates[paneId]?.connectionState else { return false }
        return TerminalManualReconnectPolicy.shouldAttemptReconnect(
            reconnectInFlight: false,
            snapshotState: state,
            hasLiveRuntime: hasLiveRuntime(forPaneId: paneId)
        )
    }

    private func canRunPaneCredentialLoad(paneId: UUID, server: Server) -> Bool {
        guard !Task.isCancelled else { return false }
        return paneStates[paneId]?.serverId == server.id
    }

    private func canRunPaneHostRetrust(paneId: UUID, server: Server) -> Bool {
        guard !Task.isCancelled else { return false }
        return paneStates[paneId]?.serverId == server.id
    }
}
