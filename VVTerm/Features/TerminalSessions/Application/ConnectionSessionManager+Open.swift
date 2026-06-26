import Foundation
import os.log

extension ConnectionSessionManager {
    @discardableResult
    func requestConnectionOpen(
        to server: Server,
        forceNew: Bool = false,
        onOpened: @escaping @MainActor (ConnectionSession) -> Void = { _ in },
        onFailed: @escaping @MainActor (Error) -> Void = { _ in }
    ) -> UUID {
        let requestID = UUID()
        lastConnectionOpenFailure = nil

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.connectionOpenRequestStore.remove(id: requestID) }

            do {
                let session = try await self.openConnection(to: server, forceNew: forceNew)
                onOpened(session)
            } catch is CancellationError {
                return
            } catch {
                self.lastConnectionOpenFailure = error
                onFailed(error)
            }
        }

        connectionOpenRequestStore.insert(task, id: requestID)
        return requestID
    }

    func waitForConnectionOpenRequest(_ requestID: UUID) async {
        await connectionOpenRequestStore[requestID]?.value
    }

    /// Opens a connection to a server
    /// - Parameters:
    ///   - server: The server to connect to
    ///   - forceNew: If true, always creates a new tab even if one exists for this server
    func openConnection(to server: Server, forceNew: Bool = false) async throws -> ConnectionSession {
        if let disconnectTask = serverDisconnectTaskStore.task(forServer: server.id) {
            logger.info("Open waiting for disconnect cleanup [serverId: \(server.id.uuidString, privacy: .public)]")
            await disconnectTask.value
        }
        await waitForServerTeardownTasks(server.id)

        // Check if server is locked due to downgrade
        if serverLockPolicy(server) {
            throw VVTermError.serverLocked(server.name)
        }

        if !connectionOpenRequestStore.beginOpen(forScope: server.id) {
            throw VVTermError.connectionFailed(
                String(localized: "A connection is already opening for this server.")
            )
        }
        defer { connectionOpenRequestStore.finishOpen(forScope: server.id) }

        guard await serverUnlocker(server) else {
            throw VVTermError.authenticationFailed
        }

        // Check if already have a session for this server (unless forcing new)
        if !forceNew, let existingSession = firstSession(for: server.id) {
            selectedSessionId = existingSession.id
            let hasLiveOrOpeningRuntime = terminalConnectionRegistry.isOpeningOrStreaming(.session(existingSession.id))
            if !hasLiveOrOpeningRuntime {
                try await reconnect(session: existingSession)
            }
            return existingSession
        }

        guard canOpenNewTab else {
            throw VVTermError.proRequired(String(localized: "Upgrade to Pro for multiple connections"))
        }

        let sourceSession = sourceSessionForNewTab(on: server.id)
        var sourceWorkingDirectory = sourceSession?.workingDirectory
        if tmuxResolver.isTmuxEnabled(for: server.id),
           let sourceSession,
           let client = sshClient(for: sourceSession),
           let path = await RemoteTmuxManager.shared.currentPath(
               sessionName: tmuxResolver.sessionName(for: sourceSession.id),
               using: client
           ) {
            sourceWorkingDirectory = path
            if let index = indexOfSession(sourceSession.id) {
                sessions[index].workingDirectory = path
            }
        }

        // Create new session - actual SSH connection happens in SSHTerminalWrapper
        let session = ConnectionSession(
            serverId: server.id,
            title: server.name,
            connectionState: .connecting,  // Will connect when terminal view appears
            tmuxStatus: tmuxResolver.isTmuxEnabled(for: server.id) ? .unknown : .off,
            workingDirectory: sourceWorkingDirectory
        )

        sessions.append(session)
        selectedSessionId = session.id

        scheduleLastConnectedUpdate(for: server)

        logger.info("Created session for \(server.name)")
        return session
    }

    func scheduleLastConnectedUpdate(for server: Server) {
        guard lastConnectedUpdateTaskStore.task(forServer: server.id) == nil else { return }

        let task = Task { @MainActor [weak self] in
            defer {
                self?.lastConnectedUpdateTaskStore.removeTask(forServer: server.id)
            }
            do {
                try await Task.sleep(for: .milliseconds(350))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.lastConnectedUpdater(server)
        }
        lastConnectedUpdateTaskStore.setTask(task, forServer: server.id)
    }

    func sourceSessionForNewTab(on serverId: UUID) -> ConnectionSession? {
        if let selectedSessionId = selectedSessionByServer[serverId],
           let session = sessionWithID(selectedSessionId),
           session.serverId == serverId {
            return session
        }

        if let selectedSessionId,
           let session = sessionWithID(selectedSessionId),
           session.serverId == serverId {
            return session
        }

        return firstSession(for: serverId)
    }
}
