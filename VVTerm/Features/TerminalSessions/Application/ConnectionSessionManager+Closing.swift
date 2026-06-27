import Foundation
import os.log

extension ConnectionSessionManager {
    /// Closes a terminal session and removes it from the list.
    func closeSession(_ session: ConnectionSession, notingSessionEnd: Bool = true) {
        guard let closeResult = closeSessionUI(session, notingSessionEnd: notingSessionEnd) else { return }
        let teardownTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for task in closeResult.richPasteUploadTasks {
                await task.value
            }
            await self.runShellTeardown(closeResult.shellTeardownRequest)
            await self.unregisterSSHClient(
                for: closeResult.sessionId,
                killingManagedTmuxSessionNamed: closeResult.tmuxSessionNameToKill
            )
        }
        trackServerTeardownTask(teardownTask, for: closeResult.serverId)
    }

    /// Closes a terminal session and waits for shell cancellation and SSH teardown to finish.
    func closeSessionAndWait(_ session: ConnectionSession, notingSessionEnd: Bool = true) async {
        await waitForServerTeardownTasks(session.serverId)
        guard let closeResult = closeSessionUI(session, notingSessionEnd: notingSessionEnd) else { return }
        for task in closeResult.richPasteUploadTasks {
            await task.value
        }
        await runShellTeardown(closeResult.shellTeardownRequest)
        await unregisterSSHClient(
            for: closeResult.sessionId,
            killingManagedTmuxSessionNamed: closeResult.tmuxSessionNameToKill
        )
    }

    /// Fully disconnects all sessions for a server and clears connection state.
    /// Closes every session during app termination: lifecycle teardown,
    /// not a user-initiated session end.
    func disconnectAll() {
        let sessionsToClose = sessions
        for session in sessionsToClose {
            closeSession(session, notingSessionEnd: false)
        }
        logger.info("Disconnected all sessions")
    }

    /// Closes every session and waits for SSH and shell teardown to finish.
    func disconnectAllAndWait() async {
        await waitForAllServerTeardownTasks()
        let sessionsToClose = sessions
        for session in sessionsToClose {
            await closeSessionAndWait(session, notingSessionEnd: false)
        }
        await waitForAllServerTeardownTasks()
        logger.info("Disconnected all sessions after awaiting teardown")
    }

    /// Disconnects all sessions without removing tabs, used when app backgrounds.
    func suspendAllForBackground() async {
        guard !isSuspendingForBackground else { return }
        setSuspendingForBackground(true)
        defer { setSuspendingForBackground(false) }

        pauseCachedTerminalsForBackground()
        let sessionsToSuspend = sessions
        var unregisterResults: [SSHUnregisterResult] = []
        unregisterResults.reserveCapacity(sessionsToSuspend.count)
        for session in sessionsToSuspend {
            if terminalConnectionRegistry.isOpeningOrStreaming(.session(session.id)) {
                updateSessionState(session.id, to: .disconnected)
                markTerminalForReconnectReset(for: session.id)
            }
            // Cancel any in-flight connects while preserving terminal state.
            await shellHandlerStore.suspendHandler(for: session.id)?()
            unregisterResults.append(takeSSHClientRegistration(for: session.id))
        }

        if unregisterResults.contains(where: { $0.shellToClose != nil || $0.clientToDisconnect != nil }) {
            await withTaskGroup(of: Void.self) { group in
                for unregisterResult in unregisterResults {
                    group.addTask {
                        await ConnectionSessionManager.finishSSHCleanup(for: unregisterResult)
                    }
                }
            }
        }

        logger.info("Suspended all sessions for background")
    }

    /// Handle shell exit without removing the session, keeping the tab for reconnect.
    func handleShellExit(for sessionId: UUID) {
        let serverId = sessionWithID(sessionId)?.serverId
        setPresentationOverrides(.empty, for: sessionId)
        terminalSurfaceRegistry.surface(for: .session(sessionId))?.applyPresentationOverrides(.empty)
        updateSessionState(sessionId, to: .disconnected)
        markTerminalForReconnectReset(for: sessionId)
        let unregisterTask = scheduleSSHUnregister(for: sessionId)
        if let serverId {
            trackServerTeardownTask(unregisterTask, for: serverId)
        }
    }

    @discardableResult
    func requestSessionProcessExit(forSession sessionId: UUID) -> UUID? {
        guard sessionWithID(sessionId) != nil else { return nil }

        if let existingRequestID = processExitRequestStore.requestID(forScope: sessionId) {
            return existingRequestID
        }

        let requestID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.processExitRequestStore.remove(id: requestID, ifMappedTo: sessionId)
            }

            guard !Task.isCancelled else { return }
            guard self.sessionWithID(sessionId) != nil else { return }

            #if DEBUG
            if let processExitOperationForTesting = self.processExitOperationForTesting {
                await processExitOperationForTesting(.session(sessionId))
                return
            }
            #endif

            self.handleShellExit(for: sessionId)
        }

        processExitRequestStore.insert(
            ProcessExitRequest(sessionId: sessionId, task: task),
            id: requestID,
            scopeID: sessionId
        )
        return requestID
    }

    /// Disconnect all sessions for a specific server.
    func disconnectServer(_ serverId: UUID) {
        let sessionsToClose = sessions.filter { $0.serverId == serverId }
        for session in sessionsToClose {
            closeSession(session)
        }
        logger.info("Disconnected all sessions for server \(serverId)")
    }

    /// Disconnect all sessions for a server and wait until SSH clients/shells are unregistered.
    /// Use this for explicit user disconnects that may be followed immediately by a new connect.
    func disconnectServerAndWait(_ serverId: UUID) async {
        if let existingTask = serverDisconnectTaskStore.task(forServer: serverId) {
            await existingTask.value
            return
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performDisconnectServerAndWait(serverId)
        }
        serverDisconnectTaskStore.setTask(task, forServer: serverId)
        await task.value
        serverDisconnectTaskStore.removeTask(forServer: serverId)
    }

    func closeOtherSessions(except session: ConnectionSession) {
        let toClose = sessions.filter { $0.id != session.id }
        for s in toClose {
            closeSession(s)
        }
    }

    func closeSessionsToLeft(of session: ConnectionSession) {
        guard let index = indexOfSession(session.id) else { return }
        let toClose = Array(sessions[..<index])
        for s in toClose {
            closeSession(s)
        }
    }

    func closeSessionsToRight(of session: ConnectionSession) {
        guard let index = indexOfSession(session.id) else { return }
        let toClose = Array(sessions[(index + 1)...])
        for s in toClose {
            closeSession(s)
        }
    }

    func registerShellCancelHandler(_ handler: @escaping @MainActor (_ mode: ShellTeardownMode) async -> Void, for sessionId: UUID) {
        shellHandlerStore.registerCancelHandler(handler, for: sessionId)
    }

    func unregisterShellCancelHandler(for sessionId: UUID) {
        shellHandlerStore.unregisterCancelHandler(for: sessionId)
    }

    func registerShellSuspendHandler(_ handler: @escaping @MainActor () async -> Void, for sessionId: UUID) {
        shellHandlerStore.registerSuspendHandler(handler, for: sessionId)
    }

    func unregisterShellSuspendHandler(for sessionId: UUID) {
        shellHandlerStore.unregisterSuspendHandler(for: sessionId)
    }

    func cancelAndClearShellHandlers(for sessionId: UUID) -> Task<Void, Never>? {
        let handler = shellHandlerStore.takeCancelHandler(for: sessionId)
        guard let handler else {
            logger.info("No shell cancel handler registered for closed session [sessionId: \(sessionId.uuidString, privacy: .public)]")
            return nil
        }
        logger.info("Running shell cancel handler for closed session [sessionId: \(sessionId.uuidString, privacy: .public)]")
        return Task(priority: .high) { @MainActor in
            await handler(.fullDisconnect)
        }
    }

    func trackShellTeardownForClosedSession(
        sessionId: UUID,
        serverId: UUID,
        reason: String,
        operation: @escaping @MainActor () async -> Void
    ) {
        let task = Task(priority: .high) { @MainActor [logger] in
            logger.info("External shell teardown started [sessionId: \(sessionId.uuidString, privacy: .public), serverId: \(serverId.uuidString, privacy: .public), reason: \(reason, privacy: .public)]")
            await operation()
            logger.info("External shell teardown finished [sessionId: \(sessionId.uuidString, privacy: .public), serverId: \(serverId.uuidString, privacy: .public), reason: \(reason, privacy: .public)]")
        }
        trackServerTeardownTask(task, for: serverId)
    }

    func waitForServerTeardownTasks(_ serverId: UUID) async {
        while !serverTeardownTaskStore.tasks(forServer: serverId).isEmpty {
            logger.info("Open waiting for tab teardown cleanup [serverId: \(serverId.uuidString, privacy: .public), count: \(self.serverTeardownTaskStore.count(forServer: serverId))]")
            for entry in serverTeardownTaskStore.tasks(forServer: serverId) {
                await entry.task.value
                finishServerTeardownTask(entry.id, for: serverId)
            }
        }
    }

    func waitForAllServerTeardownTasks() async {
        while !serverTeardownTaskStore.isEmpty {
            for serverId in serverTeardownTaskStore.serverIDs {
                await waitForServerTeardownTasks(serverId)
            }
        }
    }

    func trackServerTeardownTask(_ task: Task<Void, Never>, for serverId: UUID) {
        let taskId = serverTeardownTaskStore.insert(task, forServer: serverId)
        logger.info("Tracking server teardown [serverId: \(serverId.uuidString, privacy: .public), taskId: \(taskId.uuidString, privacy: .public), count: \(self.serverTeardownTaskStore.count(forServer: serverId))]")

        Task { @MainActor [weak self] in
            await task.value
            guard let self else { return }
            self.finishServerTeardownTask(taskId, for: serverId)
        }
    }

    func trackShellCleanup(
        for serverId: UUID,
        reason: String,
        priority: TaskPriority = .utility,
        operation: @escaping @Sendable () async -> Void
    ) {
#if DEBUG
        let testingOperation = rejectedShellCleanupOperationForTesting
#endif
        let task = Task.detached(priority: priority) { [logger] in
            logger.info("Shell cleanup started [serverId: \(serverId.uuidString, privacy: .public), reason: \(reason, privacy: .public)]")
#if DEBUG
            if let testingOperation {
                await testingOperation()
            } else {
                await operation()
            }
#else
            await operation()
#endif
            logger.info("Shell cleanup finished [serverId: \(serverId.uuidString, privacy: .public), reason: \(reason, privacy: .public)]")
        }
        trackServerTeardownTask(task, for: serverId)
    }

    func trackTmuxKill(
        for serverId: UUID,
        sessionName: String,
        client: SSHClient,
        preferred: TerminalMultiplexer
    ) {
#if DEBUG
        let testingOperation = tmuxKillOperationForTesting
#endif
        let tmuxService = tmuxService
        let task = Task.detached(priority: .utility) { [logger, tmuxService] in
            logger.info("Managed tmux kill started [serverId: \(serverId.uuidString, privacy: .public), sessionName: \(sessionName, privacy: .public)]")
#if DEBUG
            if let testingOperation {
                await testingOperation()
            } else {
                await tmuxService.killSession(named: sessionName, using: client, preferred: preferred)
            }
#else
            await tmuxService.killSession(named: sessionName, using: client, preferred: preferred)
#endif
            logger.info("Managed tmux kill finished [serverId: \(serverId.uuidString, privacy: .public), sessionName: \(sessionName, privacy: .public)]")
        }
        trackServerTeardownTask(task, for: serverId)
    }

    @discardableResult
    func scheduleSSHUnregister(
        for sessionId: UUID,
        priority: TaskPriority = .utility,
        killingManagedTmuxSessionNamed tmuxSessionName: String? = nil
    ) -> Task<Void, Never> {
        Task.detached(priority: priority) { [weak self] in
            await self?.unregisterSSHClient(
                for: sessionId,
                killingManagedTmuxSessionNamed: tmuxSessionName
            )
        }
    }

    func unregisterSSHClient(for sessionId: UUID) async {
        await unregisterSSHClient(for: sessionId, killingManagedTmuxSessionNamed: nil)
    }

    private func closeSessionUI(_ session: ConnectionSession, notingSessionEnd: Bool) -> SessionCloseResult? {
        let sessionId = session.id
        let title = session.title
        let wasSelected = selectedSessionId == sessionId

        guard sessionWithID(sessionId) != nil else { return nil }

        let tmuxSessionToKill = managedTmuxSessionNameToKill(for: sessionId, status: session.tmuxStatus)

        let replacementSessionId = replacementSessionIDAfterClosing(
            sessionId: sessionId,
            serverId: session.serverId,
            wasSelected: wasSelected
        )

        let runtimeTeardown = clearRuntimeStateForClosedSession(sessionId)
        terminalConnectionRegistry.updateState(
            .disconnected,
            for: .session(sessionId),
            serverId: session.serverId
        )

        sessions.removeAll { $0.id == sessionId }

        if wasSelected {
            selectedSessionId = replacementSessionId
        }

        handleTerminalCloseUI(
            sessionId: sessionId,
            wasSelected: wasSelected,
            replacementSessionId: replacementSessionId
        )

        if let selectedId = replacementSessionId ?? selectedSessionId,
           let selectedSession = sessionWithID(selectedId) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.redrawSessionAfterClose(selectedSession)
            }
        }

        if notingSessionEnd {
            terminalSessionEndRecorder(!activeSessions.isEmpty, isProProvider())
        }

        logger.info("Closed terminal session \(title)")
        return SessionCloseResult(
            sessionId: sessionId,
            serverId: session.serverId,
            tmuxSessionNameToKill: tmuxSessionToKill,
            richPasteUploadTasks: runtimeTeardown.richPasteUploadTasks,
            shellTeardownRequest: runtimeTeardown.shellTeardownRequest
        )
    }

    private func replacementSessionIDAfterClosing(
        sessionId: UUID,
        serverId: UUID,
        wasSelected: Bool
    ) -> UUID? {
        guard wasSelected else { return nil }

        let serverSessions = sessions.filter { $0.serverId == serverId }
        if let index = serverSessions.firstIndex(where: { $0.id == sessionId }) {
            if index + 1 < serverSessions.count {
                return serverSessions[index + 1].id
            }
            if index > 0 {
                return serverSessions[index - 1].id
            }
        }

        return sessions.first(where: { $0.id != sessionId })?.id
    }

    private func clearRuntimeStateForClosedSession(_ sessionId: UUID) -> (
        shellTeardownRequest: ShellTeardownRequest?,
        richPasteUploadTasks: [Task<Void, Never>]
    ) {
        cancelTmuxLifecycleRequest(for: sessionId)
        cancelInstallRequests(for: sessionId)
        cancelSessionRetryRequest(for: sessionId)
        cancelActiveConnectionOpenRequest(for: sessionId)
        cancelForegroundReconnectRequest(for: sessionId)
        cancelSessionHostRetrustRequest(for: sessionId)
        cancelSessionCredentialLoadRequest(for: sessionId)
        cancelInputRequests(for: sessionId)
        let richPasteUploadTasks = cancelSessionRichPasteUploadRequests(for: sessionId)
        cancelResizeRequests(for: sessionId)
        cancelProcessExitRequests(for: sessionId)
        let shellTeardownRequest = takeShellTeardownRequestForClosedSession(sessionId)
        terminalsNeedingReconnectReset.remove(sessionId)
        terminalBrowseModeBySession.removeValue(forKey: sessionId)
        clearTmuxRuntimeState(for: sessionId)
        clearRuntimeTitle(for: sessionId)
        return (shellTeardownRequest, richPasteUploadTasks)
    }

    private func cancelInstallRequests(for sessionId: UUID) {
        if let request = tmuxInstallRequestStore.removeMappedRequest(forScope: sessionId) {
            request.task.cancel()
            request.onCompleted.forEach { $0() }
        }

        if let request = moshInstallRequestStore.removeMappedRequest(forScope: sessionId) {
            request.task.cancel()
            request.onCompleted.forEach { $0() }
        }
    }

    private func cancelTmuxLifecycleRequest(for sessionId: UUID) {
        tmuxLifecycleRequestStore.removeMappedRequest(forScope: sessionId)?.task.cancel()
    }

    private func cancelProcessExitRequests(for sessionId: UUID) {
        processExitRequestStore.removeMappedRequest(forScope: sessionId)?.task.cancel()
    }

    private func cancelSessionRetryRequest(for sessionId: UUID) {
        if let request = sessionRetryRequestStore.removeMappedRequest(forScope: sessionId) {
            request.task.cancel()
            request.onCompleted.forEach { $0(.skipped) }
        }
    }

    private func cancelActiveConnectionOpenRequest(for sessionId: UUID) {
        activeConnectionOpenRequestStore.removeScopeMapping(forScope: sessionId)?.task?.cancel()
    }

    private func cancelForegroundReconnectRequest(for sessionId: UUID) {
        foregroundReconnectRequestStore.removeScopeMapping(forScope: sessionId)?.task?.cancel()
    }

    private func cancelSessionHostRetrustRequest(for sessionId: UUID) {
        if let request = sessionHostRetrustRequestStore.removeMappedRequest(forScope: sessionId) {
            request.task.cancel()
            request.onCompleted.forEach { $0(false) }
        }
    }

    private func handleTerminalCloseUI(
        sessionId: UUID,
        wasSelected: Bool,
        replacementSessionId: UUID?
    ) {
        if let terminal = terminalSurfaceRegistry.surface(for: .session(sessionId)), terminal.isAttachedToPlatformWindow {
            terminal.pauseForClosedTerminalSurface(wasSelected: wasSelected)
        } else {
            unregisterTerminal(for: sessionId)
        }

        guard let replacementSessionId,
              let replacementTerminal = terminalSurfaceRegistry.surface(for: .session(replacementSessionId)),
              replacementTerminal.isAttachedToPlatformWindow else {
            return
        }

        DispatchQueue.main.async {
            replacementTerminal.requestInitialTerminalSurfaceFocus(isApplicationActive: self.isApplicationActive())
        }
    }

    private func redrawSessionAfterClose(_ session: ConnectionSession) {
        guard let terminal = terminalSurfaceRegistry.surface(for: .session(session.id)) else { return }
        terminal.resumeRendering()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self, weak terminal] in
            guard let terminal else { return }
            terminal.forceRefresh()

            if let size = terminal.terminalSize(),
               let self {
                Task {
                    await self.resizeSession(session.id, cols: Int(size.columns), rows: Int(size.rows))
                }
            }

            #if os(iOS)
            terminal.sendText("\u{0C}")
            #endif
        }
    }

    private func performDisconnectServerAndWait(_ serverId: UUID) async {
        await waitForServerTeardownTasks(serverId)

        let sessionsToClose = sessions.filter { $0.serverId == serverId }
        var closeResults: [SessionCloseResult] = []
        closeResults.reserveCapacity(sessionsToClose.count)

        for session in sessionsToClose {
            if let closeResult = closeSessionUI(session, notingSessionEnd: true) {
                closeResults.append(closeResult)
            }
        }

        for closeResult in closeResults {
            for task in closeResult.richPasteUploadTasks {
                await task.value
            }
            await runShellTeardown(closeResult.shellTeardownRequest)
            await unregisterSSHClient(
                for: closeResult.sessionId,
                killingManagedTmuxSessionNamed: closeResult.tmuxSessionNameToKill
            )
        }

        logger.info("Disconnected all sessions for server \(serverId)")
    }

    private func pauseCachedTerminalsForBackground() {
        #if os(iOS)
        for terminal in terminalSurfaceRegistry.allSurfaces {
            terminal.pauseForBackgroundTerminalSuspension()
        }
        #endif
    }

    private func takeShellTeardownRequestForClosedSession(_ sessionId: UUID) -> ShellTeardownRequest? {
        let handler = shellHandlerStore.takeCancelHandler(for: sessionId)
        guard let handler else {
            logger.info("No shell cancel handler registered for closed session [sessionId: \(sessionId.uuidString, privacy: .public)]")
            return nil
        }
        return ShellTeardownRequest(sessionId: sessionId, handler: handler)
    }

    private func runShellTeardown(_ request: ShellTeardownRequest?) async {
        guard let request else { return }
        logger.info("Running shell cancel handler for closed session [sessionId: \(request.sessionId.uuidString, privacy: .public)]")
        await request.handler(.fullDisconnect)
    }

    private func finishServerTeardownTask(_ taskId: UUID, for serverId: UUID) {
        guard let remainingTasks = serverTeardownTaskStore.finish(taskId, forServer: serverId) else { return }
        logger.info("Finished server teardown [serverId: \(serverId.uuidString, privacy: .public), taskId: \(taskId.uuidString, privacy: .public), remaining: \(remainingTasks)]")
    }

    private func unregisterSSHClient(
        for sessionId: UUID,
        killingManagedTmuxSessionNamed tmuxSessionName: String?
    ) async {
        let unregisterResult = takeSSHClientRegistration(for: sessionId)
        if let tmuxSessionName,
           let client = unregisterResult.shellToClose?.client {
            let preferred = sessions.first(where: { $0.id == sessionId })
                .map { tmuxResolver.multiplexer(for: $0.serverId) } ?? .tmux
            await tmuxService.killSession(named: tmuxSessionName, using: client, preferred: preferred)
        }
        await Self.finishSSHCleanup(for: unregisterResult)
    }

    private func takeSSHClientRegistration(for sessionId: UUID) -> SSHUnregisterResult {
        let unregisterResult = shellRegistry.unregister(for: sessionId)
        var shellToClose: (client: SSHClient, shellId: UUID)?
        var clientToDisconnect: SSHClient?

        if let registration = unregisterResult.registration {
            shellToClose = (client: registration.client, shellId: registration.shellId)
            if !shellRegistry.hasClientReferences(registration.client) {
                clientToDisconnect = registration.client
            }
        } else if let pendingStart = unregisterResult.pendingStart,
                  !shellRegistry.hasClientReferences(pendingStart.client) {
            clientToDisconnect = pendingStart.client
        }

        if unregisterResult.registration != nil {
            setTransport(.ssh, fallbackReason: nil, for: sessionId)
        }

        return SSHUnregisterResult(
            shellToClose: shellToClose,
            clientToDisconnect: clientToDisconnect
        )
    }

    private static func finishSSHCleanup(for unregisterResult: SSHUnregisterResult) async {
        if let shellToClose = unregisterResult.shellToClose {
            await shellToClose.client.closeShell(shellToClose.shellId)
        }

        if let clientToDisconnect = unregisterResult.clientToDisconnect {
            await clientToDisconnect.disconnect()
        }
    }
}
