import Foundation

#if DEBUG
extension TerminalTabManager {
    /// Resets manager state for deterministic integration tests.
    func resetForTesting() async {
        persistTask?.cancel()
        persistTask = nil
        for serverId in serverTeardownTaskStore.serverIDs {
            await waitForServerTeardownTasks(serverId)
        }

        let allPaneIds = Set(paneStates.keys)
            .union(shellRegistry.startsInFlight.keys)
        for paneId in allPaneIds {
            clearTmuxRuntimeState(for: paneId)
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
        successfulConnectionRecorder = { EngagementTracker.shared.recordSuccessfulConnection(id: $0, transport: $1) }
        tabsByServer = [:]
        selectedTabByServer = [:]
        selectedViewByServer = [:]
        paneStates = [:]
        tmuxAttachPrompt = nil
        terminalRegistryVersion = 0
        shellRegistry.removeAll()
        tabOpenRequestStore.removeAll().forEach { $0.cancel() }
        lastTabOpenFailure = nil
        tmuxInstallRequestStore.allRequests.forEach { $0.task.cancel() }
        tmuxInstallRequestStore.removeAll()
        moshInstallRequestStore.allRequests.forEach { $0.task.cancel() }
        moshInstallRequestStore.removeAll()
        setLastMoshInstallFailure(nil)
        paneRetryRequestStore.allRequests.forEach { $0.task.cancel() }
        paneRetryRequestStore.removeAll()
        paneHostRetrustRequestStore.allRequests.forEach { $0.task.cancel() }
        paneHostRetrustRequestStore.removeAll()
        paneCredentialLoadRequestStore.allRequests.forEach { $0.task.cancel() }
        paneCredentialLoadRequestStore.removeAll()
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
        isProProvider = {
            StoreManager.shared.isPro
        }
        defaultViewProvider = {
            ViewTabConfigurationManager.shared.effectiveDefaultTab()
        }
        serverProvider = { serverId in
            ServerManager.shared.servers.first { $0.id == serverId }
        }
        credentialsProvider = { server in
            try KeychainManager.shared.getCredentials(for: server)
        }
        serverUnlocker = { server in
            await AppLockManager.shared.ensureServerUnlocked(server)
        }
        serverTeardownTaskStore.removeAll()
        paneRuntimes.removeAll()
        terminalConnectionRegistry.removeAll()
        testingTerminalConnectionClientFactory = nil
        rejectedShellCleanupOperationForTesting = nil
        tmuxKillOperationForTesting = nil
        tmuxInstallOperationForTesting = nil
        moshInstallAndReconnectOperationForTesting = nil
        paneRetryOperationForTesting = nil
        paneHostRetrustOperationForTesting = nil
        surfaceAttachOperationForTesting = nil
        inputOperationForTesting = nil
        richPasteLeaseProviderForTesting = nil
        richPasteUploadOperationForTesting = nil
        resizeOperationForTesting = nil
        processExitOperationForTesting = nil
        tmuxCleanupStore.removeAll()
        isRestoring = false

        snapshotStore.remove()
        for terminal in terminals {
            terminal.cleanup()
        }
        for client in uniqueClients.values {
            await client.disconnect()
        }
    }

    func setTerminalConnectionClientFactoryForTesting(
        _ factory: @escaping @MainActor (TerminalEntityID, Server?) -> any TerminalConnectionClient
    ) {
        testingTerminalConnectionClientFactory = factory
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

    @discardableResult
    func requestSurfaceAttachForTesting(
        paneId: UUID,
        context: TerminalSurfaceAttachContext
    ) -> UUID? {
        requestSurfaceAttach(
            paneId: paneId,
            context: context,
            attachOperation: { [weak self] in
                guard let self else { return }
                if let surfaceAttachOperationForTesting = self.surfaceAttachOperationForTesting {
                    await surfaceAttachOperationForTesting(.pane(paneId))
                }
            }
        )
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

    func setMoshInstallAndReconnectOperationForTesting(
        _ operation: (@MainActor (UUID) async throws -> Void)?
    ) {
        moshInstallAndReconnectOperationForTesting = operation
    }

    func setPaneRetryOperationForTesting(
        _ operation: (@MainActor (UUID, Server) async -> TerminalReconnectRequestResult)?
    ) {
        paneRetryOperationForTesting = operation
    }

    func setPaneHostRetrustOperationForTesting(
        _ operation: (@MainActor (UUID, Server) async -> Bool)?
    ) {
        paneHostRetrustOperationForTesting = operation
    }

    func setCredentialsProviderForTesting(
        _ provider: @escaping @MainActor (Server) async throws -> ServerCredentials
    ) {
        credentialsProvider = provider
    }

    func setServerProviderForTesting(
        _ provider: @escaping ServerProvider
    ) {
        serverProvider = provider
    }

    func setIsProProviderForTesting(
        _ provider: @escaping IsProProvider
    ) {
        isProProvider = provider
    }

    func setDefaultViewProviderForTesting(
        _ provider: @escaping DefaultViewProvider
    ) {
        defaultViewProvider = provider
    }

    func setServerUnlockerForTesting(
        _ unlocker: @escaping @MainActor (Server) async -> Bool
    ) {
        serverUnlocker = unlocker
    }

    func beginShellStartForTesting(
        paneId: UUID,
        serverId: UUID,
        client: SSHClient
    ) -> SSHShellRegistry.Generation {
        shellRegistry.tryBeginStart(
            for: paneId,
            serverId: serverId,
            client: client
        ).generation
    }

    func closeShellRegistrationForTesting(paneId: UUID) {
        _ = shellRegistry.closeEntity(paneId)
    }

    func hasTerminalConnectionRuntimeForTesting(_ entityId: TerminalEntityID) -> Bool {
        terminalConnectionRegistry.runtime(for: entityId) != nil
    }

    func setRuntimeShellTaskForTesting(
        paneId: UUID,
        _ task: Task<Void, Never>
    ) async {
        guard let runtime = paneRuntimes[paneId] else { return }
        await runtime.runtime.setShellTask(task)
    }

    func completeRuntimeShellStartForTesting(
        paneId: UUID,
        client: SSHClient,
        shellId: UUID,
        serverId: UUID,
        generation: SSHShellRegistry.Generation
    ) -> Bool {
        let accepted = registerSSHClient(
            client,
            shellId: shellId,
            for: paneId,
            serverId: serverId,
            generation: generation,
            skipTmuxLifecycle: true
        )
        guard accepted else { return false }
        updatePaneState(paneId, connectionState: .connected)
        return true
    }

    func restorePersistedSnapshotForTesting() {
        restoreSnapshot()
    }
}
#endif
