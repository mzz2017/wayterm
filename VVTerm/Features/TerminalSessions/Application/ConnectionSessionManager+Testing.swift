import Foundation

#if DEBUG
extension ConnectionSessionManager {
    /// Resets manager state for deterministic integration tests.
    func resetForTesting() async {
        persistTask?.cancel()
        persistTask = nil
        await waitForAllServerTeardownTasks()

        let allSessionIds = Set(sessions.map(\.id))
            .union(shellRegistry.startsInFlight.keys)
        for sessionId in allSessionIds {
            clearTmuxRuntimeState(for: sessionId)
        }

        var uniqueClients: [ObjectIdentifier: SSHClient] = [:]
        for registration in shellRegistry.registrations.values {
            uniqueClients[ObjectIdentifier(registration.client)] = registration.client
        }
        for context in shellRegistry.startsInFlight.values {
            uniqueClients[ObjectIdentifier(context.client)] = context.client
        }

        let terminals = terminalSurfaceRegistry.removeAll(cleanup: false)
        isRestoring = true
        restoreLiveDependencies()
        sessions = []
        selectedSessionId = nil
        selectedViewByServer = [:]
        selectedSessionByServer = [:]
        tmuxAttachPrompt = nil
        shellRegistry.removeAll()
        shellHandlerStore.removeAll()
        connectionOpenRequestStore.removeAll().forEach { $0.cancel() }
        lastConnectionOpenFailure = nil
        tmuxInstallRequestStore.allRequests.forEach { $0.task.cancel() }
        tmuxInstallRequestStore.removeAll()
        tmuxLifecycleRequestStore.allRequests.forEach { $0.task.cancel() }
        tmuxLifecycleRequestStore.removeAll()
        moshInstallRequestStore.allRequests.forEach { $0.task.cancel() }
        moshInstallRequestStore.removeAll()
        setLastMoshInstallFailure(nil)
        sessionRetryRequestStore.allRequests.forEach { $0.task.cancel() }
        sessionRetryRequestStore.removeAll()
        activeConnectionOpenRequestStore.allRequests.compactMap(\.task).forEach { $0.cancel() }
        activeConnectionOpenRequestStore.removeAll()
        foregroundReconnectRequestStore.allRequests.compactMap(\.task).forEach { $0.cancel() }
        foregroundReconnectRequestStore.removeAll()
        sessionHostRetrustRequestStore.allRequests.forEach { $0.task.cancel() }
        sessionHostRetrustRequestStore.removeAll()
        sessionCredentialLoadRequestStore.allRequests.forEach { $0.task.cancel() }
        sessionCredentialLoadRequestStore.removeAll()
        surfaceAttachRequestStore.allRequests.forEach { $0.task.cancel() }
        surfaceAttachRequestStore.removeAll()
        inputRequestStore.allRequests.forEach { $0.task.cancel() }
        inputRequestStore.removeAll()
        let richPasteUploadTasks = richPasteUploadRequestStore.allRequests.map(\.task)
        richPasteUploadTasks.forEach { $0.cancel() }
        for task in richPasteUploadTasks {
            await task.value
        }
        richPasteUploadRequestStore.removeAll()
        resizeRequestStore.allRequests.forEach { $0.task.cancel() }
        resizeRequestStore.removeAll()
        processExitRequestStore.allRequests.forEach { $0.task.cancel() }
        processExitRequestStore.removeAll()
        reconnectInFlightStore.removeAll()
        connectWatchdogStore.removeAll().forEach { $0.cancel() }
        let lastConnectedUpdateTasks = lastConnectedUpdateTaskStore.removeAll()
        lastConnectedUpdateTasks.forEach { $0.cancel() }
        for task in lastConnectedUpdateTasks {
            await task.value
        }
        restoreLiveDependencies()
        serverDisconnectTaskStore.removeAll()
        terminalsNeedingReconnectReset.removeAll()
        setSuspendingForBackground(false)
        tmuxCleanupStore.removeAll()
        sessionRuntimes.removeAll()
        terminalConnectionRegistry.removeAll()
        testingTerminalConnectionClientFactory = nil
        rejectedShellCleanupOperationForTesting = nil
        tmuxKillOperationForTesting = nil
        tmuxInstallOperationForTesting = nil
        tmuxLifecycleOperationForTesting = nil
        moshInstallAndReconnectOperationForTesting = nil
        sessionRetryOperationForTesting = nil
        activeConnectionOpenReconnectOperationForTesting = nil
        sessionHostRetrustOperationForTesting = nil
        surfaceAttachOperationForTesting = nil
        inputOperationForTesting = nil
        richPasteLeaseProviderForTesting = nil
        richPasteUploadOperationForTesting = nil
        resizeOperationForTesting = nil
        processExitOperationForTesting = nil
        sshUnregisterScheduleOperationForTesting = nil
        isRestoring = false

        snapshotStore.remove()
        for terminal in terminals {
            terminal.cleanup()
        }
        for client in uniqueClients.values {
            await client.disconnect()
        }
    }

    func setBackgroundSuspendInProgressForTesting(_ isSuspending: Bool) {
        setSuspendingForBackground(isSuspending)
    }

    func setSurfaceAttachOperationForTesting(
        _ operation: (@MainActor (TerminalEntityID) async -> Void)?
    ) {
        surfaceAttachOperationForTesting = operation
    }

    func setInputOperationForTesting(
        _ operation: (@MainActor (Data, TerminalEntityID) async -> Void)?
    ) {
        inputOperationForTesting = operation
    }

    func setRichPasteLeaseProviderForTesting(
        _ provider: (@MainActor (UUID) -> RemoteConnectionLease?)?
    ) {
        richPasteLeaseProviderForTesting = provider
    }

    func setRichPasteUploadOperationForTesting(
        _ operation: TerminalRichPasteUploadOperation?
    ) {
        richPasteUploadOperationForTesting = operation
    }

    func setResizeOperationForTesting(
        _ operation: (@MainActor (TerminalResizeRequestSize, TerminalEntityID) async -> Void)?
    ) {
        resizeOperationForTesting = operation
    }

    func setProcessExitOperationForTesting(
        _ operation: (@MainActor (TerminalEntityID) async -> Void)?
    ) {
        processExitOperationForTesting = operation
    }

    func setSSHUnregisterScheduleOperationForTesting(
        _ operation: (@MainActor (UUID) -> Void)?
    ) {
        sshUnregisterScheduleOperationForTesting = operation
    }

    @discardableResult
    func requestSurfaceAttachForTesting(
        sessionId: UUID,
        context: TerminalSurfaceAttachContext,
        resetTerminal: @escaping @MainActor () -> Void = {}
    ) -> UUID? {
        requestSurfaceAttach(
            sessionId: sessionId,
            context: context,
            resetTerminal: resetTerminal,
            attachOperation: { [weak self] in
                guard let self else { return }
                if let surfaceAttachOperationForTesting = self.surfaceAttachOperationForTesting {
                    await surfaceAttachOperationForTesting(.session(sessionId))
                }
            }
        )
    }

    func setServerDisconnectTaskForTesting(_ serverId: UUID, task: Task<Void, Never>?) {
        serverDisconnectTaskStore.setTask(task, forServer: serverId)
    }

    func setTerminalConnectionClientFactoryForTesting(
        _ factory: @escaping @MainActor (TerminalEntityID, Server?) -> any TerminalConnectionClient
    ) {
        testingTerminalConnectionClientFactory = factory
    }

    func setRejectedShellCleanupOperationForTesting(
        _ operation: (@MainActor @Sendable () async -> Void)?
    ) {
        rejectedShellCleanupOperationForTesting = operation
    }

    func setTmuxKillOperationForTesting(
        _ operation: (@MainActor @Sendable () async -> Void)?
    ) {
        tmuxKillOperationForTesting = operation
    }

    func setTmuxInstallOperationForTesting(
        _ operation: (@MainActor (UUID) async -> Void)?
    ) {
        tmuxInstallOperationForTesting = operation
    }

    func setTmuxLifecycleOperationForTesting(
        _ operation: (@MainActor (UUID, UUID, UUID) async -> Void)?
    ) {
        tmuxLifecycleOperationForTesting = operation
    }

    func setMoshInstallAndReconnectOperationForTesting(
        _ operation: (@MainActor (ConnectionSession) async throws -> Void)?
    ) {
        moshInstallAndReconnectOperationForTesting = operation
    }

    func setSessionRetryOperationForTesting(
        _ operation: (@MainActor (ConnectionSession, Server?) async -> TerminalReconnectRequestResult)?
    ) {
        sessionRetryOperationForTesting = operation
    }

    func setActiveConnectionOpenReconnectOperationForTesting(
        _ operation: (@MainActor (ConnectionSession) async -> Bool)?
    ) {
        activeConnectionOpenReconnectOperationForTesting = operation
    }

    func cancelActiveConnectionOpenRequestForTesting(_ requestID: UUID) {
        activeConnectionOpenRequestStore[requestID]?.task?.cancel()
    }

    func setForegroundReconnectOperationForTesting(
        _ operation: (@MainActor (ConnectionSession) async -> Bool)?
    ) {
        foregroundReconnectOperationForTesting = operation
    }

    func setSessionHostRetrustOperationForTesting(
        _ operation: (@MainActor (ConnectionSession, Server) async -> Bool)?
    ) {
        sessionHostRetrustOperationForTesting = operation
    }

    func setCredentialsProviderForTesting(
        _ provider: @escaping CredentialsProvider
    ) {
        credentialsProvider = provider
    }

    func setTmuxServiceForTesting(_ service: any TerminalTmuxServicing) {
        tmuxService = service
    }

    func setTmuxPreferencesForTesting(_ preferences: any TmuxAttachPreferenceProviding) {
        tmuxPreferences = preferences
    }

    func setApplicationActiveStateProviderForTesting(_ provider: @escaping ApplicationActiveStateProvider) {
        isApplicationActive = provider
    }

    func setVoiceInputCancellerForTesting(_ canceller: @escaping VoiceInputCanceller) {
        voiceInputCanceller = canceller
    }

    func setMoshServiceForTesting(_ service: any TerminalMoshServicing) {
        moshService = service
    }

    func setKnownHostTrustApproverForTesting(
        _ approver: @escaping KnownHostTrustApprover
    ) {
        knownHostTrustApprover = approver
    }

    func setWorkingDirectoryServiceForTesting(_ service: any TerminalWorkingDirectoryApplying) {
        workingDirectoryService = service
    }

    func setServerProviderForTesting(
        _ provider: @escaping ServerProvider
    ) {
        serverProvider = provider
    }

    func setServerLockPolicyForTesting(
        _ policy: @escaping ServerLockPolicy
    ) {
        serverLockPolicy = policy
    }

    func setServerUnlockerForTesting(
        _ unlocker: @escaping ServerUnlocker
    ) {
        serverUnlocker = unlocker
    }

    func setLastConnectedUpdaterForTesting(
        _ updater: @escaping LastConnectedUpdater
    ) {
        lastConnectedUpdater = updater
    }

    func setIsProProviderForTesting(
        _ provider: @escaping IsProProvider
    ) {
        isProProvider = provider
    }

    func waitForLastConnectedUpdateForTesting(serverId: UUID) async {
        await lastConnectedUpdateTaskStore.task(forServer: serverId)?.value
    }

    func registerTerminalForTesting(sessionId: UUID) {
        evictOldTerminalsIfNeeded()
        terminalSurfaceRegistry.registerForTesting(
            entityId: .session(sessionId),
            pause: {},
            cleanup: {}
        )
    }

    func beginShellStartForTesting(
        sessionId: UUID,
        serverId: UUID,
        client: SSHClient
    ) -> SSHShellRegistry.Generation {
        shellRegistry.tryBeginStart(
            for: sessionId,
            serverId: serverId,
            client: client
        ).generation
    }

    func closeShellRegistrationForTesting(sessionId: UUID) {
        _ = shellRegistry.closeEntity(sessionId)
    }

    func hasTerminalConnectionRuntimeForTesting(_ entityId: TerminalEntityID) -> Bool {
        terminalConnectionRegistry.runtime(for: entityId) != nil
    }

    func setRuntimeShellTaskForTesting(
        sessionId: UUID,
        _ task: Task<Void, Never>
    ) async {
        guard let runtime = sessionRuntimes[sessionId] else { return }
        await runtime.runtime.setShellTask(task)
        registerShellCancelHandler({ [weak self] mode in
            await self?.cancelRuntime(for: sessionId, mode: mode, cleanupTerminal: false)
        }, for: sessionId)
    }

    func completeRuntimeShellStartForTesting(
        sessionId: UUID,
        client: SSHClient,
        shellId: UUID,
        serverId: UUID,
        generation: SSHShellRegistry.Generation
    ) -> Bool {
        let accepted = registerSSHClient(
            client,
            shellId: shellId,
            for: sessionId,
            serverId: serverId,
            generation: generation,
            skipTmuxLifecycle: true
        )
        guard accepted else { return false }
        updateSessionState(sessionId, to: .connected)
        return true
    }

    func restorePersistedSnapshotForTesting() {
        restoreSnapshot()
    }
}
#endif
