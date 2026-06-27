import Foundation

extension ConnectionSessionManager {
    func reconnect(session: ConnectionSession) async throws {
        guard !isSuspendingForBackground else { return }
        guard serverProvider(session.serverId) != nil else {
            throw SSHError.connectionFailed("Server not found")
        }

        if terminalConnectionRegistry.isOpeningOrStreaming(.session(session.id)) {
            return
        }

        updateSessionState(session.id, to: .reconnecting(attempt: 1))
        markTerminalForReconnectReset(for: session.id)

        await shellHandlerStore.suspendHandler(for: session.id)?()
        await unregisterSSHClient(for: session.id)
    }

    func reconnectSessionIfRuntimeInactive(_ session: ConnectionSession) async -> Bool {
        guard canStartSessionReconnect(session.id) else {
            return false
        }

        do {
            try await reconnect(session: session)
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    func requestActiveConnectionOpen(
        session: ConnectionSession,
        preferredViewId: String,
        onOpened: @escaping @MainActor () -> Void = {}
    ) -> UUID {
        if let requestID = activeConnectionOpenRequestStore.requestID(forScope: session.id) {
            activeConnectionOpenRequestStore.update(requestID) { $0.onOpened.append(onOpened) }
            return requestID
        }

        let requestID = UUID()
        activeConnectionOpenRequestStore.insert(
            ActiveConnectionOpenRequest(
                sessionId: session.id,
                task: nil,
                onOpened: [onOpened]
            ),
            id: requestID,
            scopeID: session.id
        )

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.activeConnectionOpenRequestStore.remove(id: requestID, ifMappedTo: session.id)
            }

            #if DEBUG
            if let operation = self.activeConnectionOpenReconnectOperationForTesting {
                _ = await operation(session)
            } else {
                _ = await self.reconnectSessionIfRuntimeInactive(session)
            }
            #else
            _ = await self.reconnectSessionIfRuntimeInactive(session)
            #endif

            guard !Task.isCancelled else { return }
            guard self.sessionWithID(session.id) != nil else { return }

            self.selectSession(session)
            self.selectedViewByServer[session.serverId] = preferredViewId

            let callbacks = self.activeConnectionOpenRequestStore[requestID]?.onOpened ?? []
            callbacks.forEach { $0() }
        }

        if activeConnectionOpenRequestStore[requestID]?.sessionId == session.id {
            activeConnectionOpenRequestStore.update(requestID) { $0.task = task }
        }

        return requestID
    }

    @discardableResult
    func requestForegroundReconnectForSelectedSession(
        selectedViewId: String,
        terminalViewId: String,
        refreshTerminal: Bool,
        autoReconnectEnabled: Bool,
        onAction: @escaping @MainActor (TerminalForegroundReconnectAction) -> Void = { _ in }
    ) -> UUID? {
        guard let action = foregroundReconnectActionForSelectedSession(
            selectedViewId: selectedViewId,
            terminalViewId: terminalViewId,
            refreshTerminal: refreshTerminal,
            autoReconnectEnabled: autoReconnectEnabled
        ) else {
            return nil
        }

        if let requestID = foregroundReconnectRequestStore.requestID(forScope: action.sessionId) {
            foregroundReconnectRequestStore.update(requestID) {
                $0.callbacks.append(
                    ForegroundReconnectCallback(action: action, onAction: onAction)
                )
            }
            return requestID
        }

        let requestID = UUID()
        foregroundReconnectRequestStore.insert(
            ForegroundReconnectRequest(
                sessionId: action.sessionId,
                task: nil,
                callbacks: [ForegroundReconnectCallback(action: action, onAction: onAction)]
            ),
            id: requestID,
            scopeID: action.sessionId
        )

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.foregroundReconnectRequestStore.remove(id: requestID, ifMappedTo: action.sessionId)
            }

            if action.shouldReconnect,
               let session = self.sessionWithID(action.sessionId) {
                #if DEBUG
                if let operation = self.foregroundReconnectOperationForTesting {
                    _ = await operation(session)
                } else {
                    _ = await self.reconnectSessionIfRuntimeInactive(session)
                }
                #else
                _ = await self.reconnectSessionIfRuntimeInactive(session)
                #endif
            }

            guard !Task.isCancelled else { return }
            guard self.selectedSessionId == action.sessionId else { return }
            guard self.sessionWithID(action.sessionId) != nil else { return }

            let callbacks = self.foregroundReconnectRequestStore[requestID]?.callbacks ?? []
            callbacks.forEach { $0.onAction($0.action) }
        }

        if foregroundReconnectRequestStore[requestID]?.sessionId == action.sessionId {
            foregroundReconnectRequestStore.update(requestID) { $0.task = task }
        }

        return requestID
    }

    func retrySessionConnection(
        session: ConnectionSession,
        server: Server?
    ) async -> TerminalReconnectRequestResult {
        guard let server else {
            return .credentialLoadFailed(String(localized: "Failed to load credentials"))
        }
        guard shouldManuallyReconnectSession(
            session.id,
            reconnectInFlight: reconnectInFlightStore.contains(session.id)
        ) else {
            return .skipped
        }
        guard reconnectInFlightStore.begin(session.id) else {
            return .skipped
        }

        defer { reconnectInFlightStore.finish(session.id) }

        do {
            let credentials = try await credentialsProvider(server)
            guard canStartSessionReconnect(session.id) else {
                return .skipped
            }
            try await reconnect(session: session)
            return .started(credentials)
        } catch {
            return .credentialLoadFailed(error.localizedDescription)
        }
    }

    @discardableResult
    func requestSessionRetry(
        session: ConnectionSession,
        server: Server?,
        onCompleted: @escaping @MainActor (TerminalReconnectRequestResult) -> Void = { _ in }
    ) -> UUID {
        if let requestID = sessionRetryRequestStore.requestID(forScope: session.id) {
            sessionRetryRequestStore.update(requestID) { $0.onCompleted.append(onCompleted) }
            return requestID
        }

        let requestID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.sessionRetryRequestStore.remove(id: requestID, ifMappedTo: session.id)
            }

            #if DEBUG
            let result: TerminalReconnectRequestResult
            if let operation = self.sessionRetryOperationForTesting {
                result = await operation(session, server)
            } else {
                result = await self.retrySessionConnection(session: session, server: server)
            }
            #else
            let result = await self.retrySessionConnection(session: session, server: server)
            #endif

            let callbacks = self.sessionRetryRequestStore[requestID]?.onCompleted ?? []
            callbacks.forEach { $0(Task.isCancelled ? .skipped : result) }
        }
        sessionRetryRequestStore.insert(
            SessionRetryRequest(
                sessionId: session.id,
                task: task,
                onCompleted: [onCompleted]
            ),
            id: requestID,
            scopeID: session.id
        )
        return requestID
    }

    func waitForSessionRetryRequest(_ requestID: UUID) async {
        await sessionRetryRequestStore[requestID]?.task.value
    }

    func loadCredentials(for server: Server) async -> TerminalCredentialLoadResult {
        do {
            return .loaded(try await credentialsProvider(server))
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    @discardableResult
    func requestSessionCredentialLoad(
        session: ConnectionSession,
        server: Server,
        onCompleted: @escaping @MainActor (TerminalCredentialLoadResult) -> Void = { _ in }
    ) -> UUID {
        if let requestID = sessionCredentialLoadRequestStore.requestID(forScope: session.id) {
            sessionCredentialLoadRequestStore.update(requestID) { $0.onCompleted.append(onCompleted) }
            return requestID
        }

        let requestID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.sessionCredentialLoadRequestStore.remove(id: requestID, ifMappedTo: session.id)
            }

            guard self.canRunSessionCredentialLoad(session: session, server: server) else { return }
            let result = await self.loadCredentials(for: server)
            guard self.canRunSessionCredentialLoad(session: session, server: server) else { return }

            let callbacks = self.sessionCredentialLoadRequestStore[requestID]?.onCompleted ?? []
            callbacks.forEach { $0(result) }
        }
        sessionCredentialLoadRequestStore.insert(
            SessionCredentialLoadRequest(
                sessionId: session.id,
                task: task,
                onCompleted: [onCompleted]
            ),
            id: requestID,
            scopeID: session.id
        )
        return requestID
    }

    func waitForSessionCredentialLoadRequest(_ requestID: UUID) async {
        await sessionCredentialLoadRequestStore[requestID]?.task.value
    }

    func cancelSessionCredentialLoadRequest(for sessionId: UUID) {
        sessionCredentialLoadRequestStore.removeScopeMapping(forScope: sessionId)?.task.cancel()
    }

    func retrustHostAndReconnect(session: ConnectionSession, server: Server) async -> Bool {
        guard canRunSessionHostRetrust(session: session, server: server) else { return false }
        await knownHostRemover(server.host, server.port)
        guard canRunSessionHostRetrust(session: session, server: server) else { return false }
        do {
            try await reconnect(session: session)
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    func requestSessionHostRetrust(
        session: ConnectionSession,
        server: Server,
        onCompleted: @escaping @MainActor (Bool) -> Void = { _ in }
    ) -> UUID {
        if let requestID = sessionHostRetrustRequestStore.requestID(forScope: session.id) {
            sessionHostRetrustRequestStore.update(requestID) { $0.onCompleted.append(onCompleted) }
            return requestID
        }

        let requestID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.sessionHostRetrustRequestStore.remove(id: requestID, ifMappedTo: session.id)
            }

            guard self.canRunSessionHostRetrust(session: session, server: server) else {
                let callbacks = self.sessionHostRetrustRequestStore[requestID]?.onCompleted ?? []
                callbacks.forEach { $0(false) }
                return
            }

            #if DEBUG
            let didReconnect: Bool
            if let operation = self.sessionHostRetrustOperationForTesting {
                didReconnect = await operation(session, server)
            } else {
                didReconnect = await self.retrustHostAndReconnect(session: session, server: server)
            }
            #else
            let didReconnect = await self.retrustHostAndReconnect(session: session, server: server)
            #endif

            let callbacks = self.sessionHostRetrustRequestStore[requestID]?.onCompleted ?? []
            callbacks.forEach {
                $0(self.canRunSessionHostRetrust(session: session, server: server) ? didReconnect : false)
            }
        }
        sessionHostRetrustRequestStore.insert(
            SessionHostRetrustRequest(
                sessionId: session.id,
                task: task,
                onCompleted: [onCompleted]
            ),
            id: requestID,
            scopeID: session.id
        )
        return requestID
    }

    func waitForSessionHostRetrustRequest(_ requestID: UUID) async {
        await sessionHostRetrustRequestStore[requestID]?.task.value
    }

    func installMoshServerAndReconnect(session: ConnectionSession) async throws {
        try await installMoshServer(for: session.id)
        try await reconnect(session: session)
    }

    @discardableResult
    func requestTmuxInstall(
        for sessionId: UUID,
        onCompleted: @escaping @MainActor () -> Void = {}
    ) -> UUID {
        if let requestID = tmuxInstallRequestStore.requestID(forScope: sessionId) {
            tmuxInstallRequestStore.update(requestID) { $0.onCompleted.append(onCompleted) }
            return requestID
        }

        let requestID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.tmuxInstallRequestStore.remove(id: requestID, ifMappedTo: sessionId)
            }

            #if DEBUG
            if let operation = self.tmuxInstallOperationForTesting {
                await operation(sessionId)
            } else {
                await self.startTmuxInstall(for: sessionId)
            }
            #else
            await self.startTmuxInstall(for: sessionId)
            #endif

            guard !Task.isCancelled else { return }
            let callbacks = self.tmuxInstallRequestStore[requestID]?.onCompleted ?? []
            callbacks.forEach { $0() }
        }
        tmuxInstallRequestStore.insert(
            TmuxInstallRequest(
                sessionId: sessionId,
                task: task,
                onCompleted: [onCompleted]
            ),
            id: requestID,
            scopeID: sessionId
        )
        return requestID
    }

    func waitForTmuxInstallRequest(_ requestID: UUID) async {
        await tmuxInstallRequestStore[requestID]?.task.value
    }

    @discardableResult
    func requestMoshInstallAndReconnect(
        session: ConnectionSession,
        onCompleted: @escaping @MainActor () -> Void = {},
        onFailed: @escaping @MainActor (Error) -> Void = { _ in }
    ) -> UUID {
        if let requestID = moshInstallRequestStore.requestID(forScope: session.id) {
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
                self.moshInstallRequestStore.remove(id: requestID, ifMappedTo: session.id)
            }

            do {
                #if DEBUG
                if let operation = self.moshInstallAndReconnectOperationForTesting {
                    try await operation(session)
                } else {
                    try await self.installMoshServerAndReconnect(session: session)
                }
                #else
                try await self.installMoshServerAndReconnect(session: session)
                #endif

                guard !Task.isCancelled else { return }
                let callbacks = self.moshInstallRequestStore[requestID]?.onCompleted ?? []
                callbacks.forEach { $0() }
            } catch is CancellationError {
                let callbacks = self.moshInstallRequestStore[requestID]?.onCompleted ?? []
                callbacks.forEach { $0() }
                return
            } catch {
                self.setLastMoshInstallFailure(error)
                let callbacks = self.moshInstallRequestStore[requestID]?.onFailed ?? []
                callbacks.forEach { $0(error) }
            }
        }
        moshInstallRequestStore.insert(
            MoshInstallRequest(
                sessionId: session.id,
                task: task,
                onCompleted: [onCompleted],
                onFailed: [onFailed]
            ),
            id: requestID,
            scopeID: session.id
        )
        return requestID
    }

    func waitForMoshInstallRequest(_ requestID: UUID) async {
        await moshInstallRequestStore[requestID]?.task.value
    }

    private func canStartSessionReconnect(_ sessionId: UUID) -> Bool {
        guard let state = sessionState(for: sessionId) else { return false }
        return TerminalManualReconnectPolicy.shouldAttemptReconnect(
            reconnectInFlight: false,
            snapshotState: state,
            hasLiveRuntime: hasLiveRuntime(forSessionId: sessionId)
        )
    }

    private func canRunSessionCredentialLoad(session: ConnectionSession, server: Server) -> Bool {
        guard !Task.isCancelled else { return false }
        return sessions.contains { $0.id == session.id && $0.serverId == server.id }
    }

    private func canRunSessionHostRetrust(session: ConnectionSession, server: Server) -> Bool {
        guard !Task.isCancelled else { return false }
        return sessions.contains { $0.id == session.id && $0.serverId == server.id }
    }
}
