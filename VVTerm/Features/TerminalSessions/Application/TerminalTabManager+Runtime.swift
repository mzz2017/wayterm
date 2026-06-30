import Foundation
import os.log

extension TerminalTabManager {
    func configureRuntime(
        forPane paneId: UUID,
        server: Server,
        credentials: ServerCredentials,
        onProcessExit: @escaping () -> Void
    ) {
        if let runtime = paneRuntimes[paneId] {
            runtime.server = server
            runtime.credentials = credentials
            runtime.onProcessExit = onProcessExit
            return
        }

        let entityId = TerminalEntityID.pane(paneId)
        let runtime = makeTerminalConnectionRuntime(entityId: entityId, server: server)
        terminalConnectionRegistry.register(runtime, for: entityId, serverId: server.id)
        paneRuntimes[paneId] = PaneRuntimeState(
            paneId: paneId,
            server: server,
            credentials: credentials,
            runtime: runtime,
            onProcessExit: onProcessExit
        )
    }

    func startRuntimeIfNeeded(forPane paneId: UUID, terminal _: GhosttyTerminalView) async {
        guard let runtime = await runtimeStateForStarting(paneId: paneId) else { return }
        await startRuntimeIfNeeded(runtime)
    }

    func registeredShellRoute(forPane paneId: UUID) -> (client: SSHClient, shellId: UUID)? {
        guard let client = getSSHClient(for: paneId),
              let shellId = shellId(for: paneId) else {
            return nil
        }
        return (client: client, shellId: shellId)
    }

    func cancelRuntime(
        forPane paneId: UUID,
        mode: ShellTeardownMode,
        cleanupTerminal: Bool,
        closeRegisteredShell: Bool
    ) async {
        let runtime = paneRuntimes[paneId]

        if cleanupTerminal {
            terminalSurfaceRegistry.removeSurface(for: .pane(paneId), cleanup: true)
        }

        guard let runtime else { return }
        await runtime.runtime.closeRunner(
            mode: mode,
            closeShell: closeRegisteredShell,
            disconnectClient: closeRegisteredShell
        )
        if mode == .fullDisconnect {
            paneRuntimes.removeValue(forKey: paneId)
            terminalConnectionRegistry.discardRuntime(for: .pane(paneId))
        }
    }

    func clearRuntimeShellForReconnect(paneId: UUID) async {
        guard let runtime = paneRuntimes[paneId] else { return }
        let runtimeClient = await runtime.runtime.runnerClientIfCreated()
        let shouldDisconnectRuntimeClient = runtimeClient.map { !shellRegistry.hasClientReferences($0) } ?? false
        await runtime.runtime.closeRunner(
            mode: .closeShellOnly,
            closeShell: false,
            disconnectClient: shouldDisconnectRuntimeClient
        )
    }

    func closeTestingRuntimeIfNeeded(forPane paneId: UUID) async -> Bool {
        guard let runtime = terminalConnectionRegistry.runtime(for: .pane(paneId)) else {
            return false
        }
        await runtime.close(mode: .fullDisconnect)
        terminalConnectionRegistry.discardRuntime(for: .pane(paneId))
        return true
    }

    /// Register SSH shell for a pane
    @discardableResult
    func registerSSHClient(
        _ client: SSHClient,
        shellId: UUID,
        for paneId: UUID,
        serverId: UUID,
        transport: ShellTransport = .ssh,
        fallbackReason: MoshFallbackReason? = nil,
        skipTmuxLifecycle: Bool = false
    ) -> Bool {
        registerSSHClient(
            client,
            shellId: shellId,
            for: paneId,
            serverId: serverId,
            transport: transport,
            fallbackReason: fallbackReason,
            generation: nil,
            skipTmuxLifecycle: skipTmuxLifecycle
        )
    }

    @discardableResult
    func registerSSHClient(
        _ client: SSHClient,
        shellId: UUID,
        for paneId: UUID,
        serverId: UUID,
        transport: ShellTransport = .ssh,
        fallbackReason: MoshFallbackReason? = nil,
        generation: SSHShellRegistry.Generation?,
        skipTmuxLifecycle: Bool = false
    ) -> Bool {
        guard paneStates[paneId] != nil else {
            logger.warning("Ignoring shell registration for missing pane \(paneId.uuidString, privacy: .public)")
            trackShellCleanup(
                for: serverId,
                reason: "missing pane shell"
            ) { [client, shellId] in
                await client.closeShell(shellId)
                await client.disconnect()
            }
            return false
        }

        let registerResult = shellRegistry.register(
            client: client,
            shellId: shellId,
            for: paneId,
            serverId: serverId,
            transport: transport,
            fallbackReason: fallbackReason,
            generation: generation
        )

        if let stale = registerResult.staleIncomingShell {
            logger.warning("Ignoring stale shell registration for pane \(paneId.uuidString, privacy: .public)")
            trackShellCleanup(
                for: serverId,
                reason: "rejected pane shell"
            ) { [client = stale.client, shellId = stale.shellId] in
                await client.closeShell(shellId)
                await client.disconnect()
            }
            return false
        }

        if let replaced = registerResult.replacedShell {
            trackShellCleanup(
                for: serverId,
                reason: "replaced pane shell"
            ) { [client = replaced.client, shellId = replaced.shellId] in
                await client.closeShell(shellId)
            }
        }

        setPaneTransport(transport, fallbackReason: fallbackReason, for: paneId)

        if !skipTmuxLifecycle {
            requestTmuxLifecycle(paneId: paneId, serverId: serverId, client: client, shellId: shellId)
        }
        return true
    }

    /// Unregister SSH shell
    func unregisterSSHClient(for paneId: UUID) async {
        await unregisterSSHClient(for: paneId, killingManagedTmuxSessionNamed: nil)
    }

    func unregisterSSHClient(
        for paneId: UUID,
        killingManagedTmuxSessionNamed tmuxSessionName: String?
    ) async {
        let unregisterResult = shellRegistry.unregister(for: paneId)

        guard let registration = unregisterResult.registration else {
            if let pendingStart = unregisterResult.pendingStart {
                if !shellRegistry.hasClientReferences(pendingStart.client) {
                    await pendingStart.client.disconnect()
                }
            }
            return
        }

        if let tmuxSessionName {
            await tmuxService.killSession(
                named: tmuxSessionName,
                using: registration.client,
                preferred: tmuxResolver.multiplexer(for: registration.serverId)
            )
        }

        await registration.client.closeShell(registration.shellId)

        if !shellRegistry.hasClientReferences(registration.client) {
            await registration.client.disconnect()
        }

        setPaneTransport(.ssh, fallbackReason: nil, for: paneId)
    }

    func remoteConnectionLease(for paneId: UUID) -> RemoteConnectionLease? {
        getSSHClient(for: paneId).map {
            RemoteConnectionLease(client: $0, ownership: .borrowed)
        }
    }

    func shellId(for paneId: UUID) -> UUID? {
        shellRegistry.shellId(for: paneId)
    }

    /// Returns true only for the first caller while no live shell exists for the pane.
    func tryBeginShellStart(for paneId: UUID, client: SSHClient) -> Bool {
        beginShellStart(for: paneId, client: client)?.started == true
    }

    func beginShellStart(for paneId: UUID, client: SSHClient) -> SSHShellRegistry.StartResult? {
        guard let serverId = paneStates[paneId]?.serverId else {
            return nil
        }

        let startResult = shellRegistry.tryBeginStart(
            for: paneId,
            serverId: serverId,
            client: client
        )

        handleStaleShellStartContext(
            startResult.staleContext,
            logMessage: "Recovered stale pane shell-start lock for",
            paneId: paneId
        )
        return startResult
    }

    func finishShellStart(for paneId: UUID, client: SSHClient, generation: SSHShellRegistry.Generation? = nil) {
        shellRegistry.finishStart(for: paneId, client: client, generation: generation)
    }

    func isShellStartInFlight(for paneId: UUID) -> Bool {
        let result = shellRegistry.isStartInFlight(for: paneId)
        handleStaleShellStartContext(
            result.staleContext,
            logMessage: "Cleared stale pane shell-start in-flight flag for",
            paneId: paneId
        )
        return result.inFlight
    }

    /// Returns true when the same SSH client instance is registered to another live pane.
    /// This is used to avoid disconnecting a truly shared client during retry cleanup.
    func hasOtherRegistrations(using client: SSHClient, excluding paneId: UUID) -> Bool {
        shellRegistry.hasOtherRegistrations(using: client, excluding: paneId)
    }

    func sharedStatsLease(for serverId: UUID) -> RemoteConnectionLease? {
        sharedStatsClient(for: serverId).map {
            RemoteConnectionLease(client: $0, ownership: .borrowed)
        }
    }

    private func makeTerminalConnectionRuntime(
        entityId: TerminalEntityID,
        server: Server?
    ) -> TerminalConnectionRuntime {
        #if DEBUG
        if let testingTerminalConnectionClientFactory {
            return TerminalConnectionRuntime(
                entityId: entityId,
                clientFactory: { testingTerminalConnectionClientFactory(entityId, server) }
            )
        }
        #endif

        return TerminalConnectionRuntime(entityId: entityId)
    }

    private func runtimeStateForStarting(paneId: UUID) async -> PaneRuntimeState? {
        if let runtime = paneRuntimes[paneId] {
            return runtime
        }

        guard let paneState = paneStates[paneId],
              let server = serverProvider(paneState.serverId) else {
            updatePaneState(paneId, connectionState: .failed("Server not found"))
            return nil
        }

        do {
            let credentials = try await credentialsProvider(server)
            configureRuntime(forPane: paneId, server: server, credentials: credentials, onProcessExit: {})
            return paneRuntimes[paneId]
        } catch {
            updatePaneState(paneId, connectionState: .failed(error.localizedDescription))
            return nil
        }
    }

    private func startRuntimeIfNeeded(_ runtime: PaneRuntimeState) async {
        let paneId = runtime.paneId

        if await runtime.runtime.hasShellTask() {
            logger.debug("Ignoring duplicate start request for pane \(paneId.uuidString, privacy: .public)")
            return
        }

        if let existingShellId = shellId(for: paneId) {
            await runtime.runtime.setShellId(existingShellId)
            updatePaneState(paneId, connectionState: .connected)
            logger.debug("Reusing existing shell for pane \(paneId.uuidString, privacy: .public)")
            return
        }

        if await runtime.runtime.currentShellId() != nil {
            updatePaneState(paneId, connectionState: .connected)
            return
        }

        let sshClient = await runtime.runtime.runnerClient()
        guard let startResult = beginShellStart(for: paneId, client: sshClient),
              startResult.started else {
            if shellId(for: paneId) != nil {
                updatePaneState(paneId, connectionState: .connected)
            }
            logger.debug("Shell start already in progress for pane \(paneId.uuidString, privacy: .public)")
            return
        }

        let server = runtime.server
        let credentials = runtime.credentials
        let terminalHandle = TerminalConnectionSurfaceHandle(
            availabilityProvider: { [weak self] in
                self?.terminalSurfaceRegistry.hasSurface(for: .pane(paneId)) ?? false
            },
            sizeProvider: { [weak self] in
                self?.terminalSurfaceRegistry.surface(for: .pane(paneId))?.connectionSurfaceSize()
            },
            outputWriter: { [weak self] data in
                self?.terminalSurfaceRegistry.surface(for: .pane(paneId))?.writeConnectionOutput(data)
            },
            exitReporter: { [weak self] exitCode in
                self?.terminalSurfaceRegistry.surface(for: .pane(paneId))?.connectionSurfaceExited(exitCode)
            }
        )
        let processExitHandler = TerminalProcessExitHandler(action: runtime.onProcessExit)
        let logger = self.logger
        let shellGeneration = startResult.generation

        await runtime.runtime.installShellTask(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            guard await terminalHandle.isAvailable() else {
                await self.finishPaneShellTask(
                    paneId: paneId,
                    client: sshClient,
                    generation: shellGeneration
                )
                return
            }
            await TerminalConnectionRunner.run(
                server: server,
                credentials: credentials,
                sshClient: sshClient,
                terminal: terminalHandle,
                logger: logger,
                onAttempt: { attempt in
                    if attempt == 1 {
                        self.updatePaneState(paneId, connectionState: .connecting)
                    } else {
                        self.updatePaneState(paneId, connectionState: .reconnecting(attempt: attempt))
                    }
                },
                startupPlan: {
                    await self.tmuxStartupPlan(
                        for: paneId,
                        serverId: server.id,
                        client: sshClient
                    )
                },
                registerShell: { shell, skipTmuxLifecycle in
                    let accepted = self.registerSSHClient(
                        sshClient,
                        shellId: shell.id,
                        for: paneId,
                        serverId: server.id,
                        transport: shell.transport,
                        fallbackReason: shell.fallbackReason,
                        generation: shellGeneration,
                        skipTmuxLifecycle: skipTmuxLifecycle
                    )
                    guard accepted else { return false }
                    await self.paneRuntimes[paneId]?.runtime.setShellId(shell.id)
                    self.updatePaneState(paneId, connectionState: .connected)
                    return true
                },
                onBeforeShellStart: { cols, rows in
                    await self.paneRuntimes[paneId]?.runtime.updateLastSize(cols: cols, rows: rows)
                },
                onShellStarted: { _, shellId in
                    await self.workingDirectoryService.apply(using: sshClient, shellId: shellId) {
                        guard self.shouldApplyWorkingDirectory(for: paneId) else { return nil }
                        return self.workingDirectory(for: paneId)
                    }
                },
                onTitleChange: { title in
                    self.updatePaneTitle(paneId, rawTitle: title)
                },
                shouldContinueStreaming: { data, terminal in
                    guard self.paneStates[paneId] != nil else { return false }
                    terminal.writeConnectionOutput(data)
                    return true
                },
                shouldResetClient: { sshError in
                    switch sshError {
                    case .notConnected, .connectionFailed, .socketError, .timeout, .libssh2:
                        return true
                    case .channelOpenFailed, .shellRequestFailed:
                        let hasOtherRegistrations = await self.hasOtherRegistrations(
                            using: sshClient,
                            excluding: paneId
                        )
                        return !hasOtherRegistrations
                    case .authenticationFailed, .tailscaleAuthenticationNotAccepted, .cloudflareConfigurationRequired, .cloudflareAuthenticationFailed, .cloudflareTunnelFailed, .hostKeyVerificationFailed, .moshServerMissing, .moshBootstrapFailed, .moshSessionFailed, .unknown:
                        return false
                    }
                },
                onProcessExit: processExitHandler,
                onFailure: { error, terminal in
                    let errorMsg = "\r\n\u{001B}[31mSSH Error: \(error.localizedDescription)\u{001B}[0m\r\n"
                    if let data = errorMsg.data(using: .utf8) {
                        terminal.writeConnectionOutput(data)
                    }
                    self.updatePaneState(paneId, connectionState: .failed(error.localizedDescription))
                }
            )
            await self.finishPaneShellTask(
                paneId: paneId,
                client: sshClient,
                generation: shellGeneration
            )
        }
    }

    private func finishPaneShellTask(
        paneId: UUID,
        client: SSHClient,
        generation: SSHShellRegistry.Generation
    ) async {
        finishShellStart(
            for: paneId,
            client: client,
            generation: generation
        )
        if let runtime = paneRuntimes[paneId]?.runtime {
            await runtime.clearShellTask(ifUsing: client)
        }
    }

    private func getSSHClient(for paneId: UUID) -> SSHClient? {
        shellRegistry.client(for: paneId)
    }

    private func preferredSSHClient(for serverId: UUID, allowPendingStart: Bool) -> SSHClient? {
        if let registration = preferredSSHRegistration(for: serverId) {
            return registration.client
        }

        if allowPendingStart, let client = shellRegistry.firstPendingClient(for: serverId) {
            return client
        }

        return nil
    }

    private func preferredSSHRegistration(for serverId: UUID) -> SSHShellRegistry.Registration? {
        if let selectedTab = selectedTab(for: serverId) {
            let preferredPaneIds = [selectedTab.focusedPaneId, selectedTab.rootPaneId] + selectedTab.allPaneIds
            for paneId in preferredPaneIds {
                if let registration = shellRegistry.registration(for: paneId) {
                    return registration
                }
            }
        }

        let serverTabs = tabs(for: serverId)
        for tab in serverTabs {
            for paneId in tab.allPaneIds {
                if let registration = shellRegistry.registration(for: paneId) {
                    return registration
                }
            }
        }

        return shellRegistry.firstRegistration(for: serverId)
    }

    /// Returns the best-known client for this server, including pending shell starts.
    private func sshClient(for serverId: UUID) -> SSHClient? {
        preferredSSHClient(for: serverId, allowPendingStart: true)
    }

    /// Returns only clients that already have a registered shell for this server.
    private func activeSSHClient(for serverId: UUID) -> SSHClient? {
        preferredSSHClient(for: serverId, allowPendingStart: false)
    }

    private func sharedStatsClient(for serverId: UUID) -> SSHClient? {
        if let livePane = registryLivePaneState(for: serverId) {
            guard let registration = shellRegistry.registration(for: livePane.paneId),
                  registration.transport != .mosh else {
                return nil
            }
            return registration.client
        }

        if let registration = preferredSSHRegistration(for: serverId) {
            guard registration.transport != .mosh else { return nil }
            return registration.client
        }

        return shellRegistry.firstPendingClient(for: serverId)
    }

    private func registryLivePaneState(for serverId: UUID) -> TerminalPaneState? {
        let liveEntityIDs = terminalConnectionRegistry.openingOrStreamingEntityIDs(for: serverId)
        if let selectedTab = selectedTab(for: serverId) {
            let preferredPaneIds = [selectedTab.focusedPaneId, selectedTab.rootPaneId] + selectedTab.allPaneIds
            for paneId in preferredPaneIds where liveEntityIDs.contains(.pane(paneId)) {
                if let state = paneStates[paneId] {
                    return state
                }
            }
        }

        return paneStates.values.first {
            $0.serverId == serverId && liveEntityIDs.contains(.pane($0.paneId))
        }
    }

    private func handleStaleShellStartContext(
        _ staleContext: SSHShellRegistry.StartContext?,
        logMessage: StaticString,
        paneId: UUID
    ) {
        guard let staleContext else { return }

        logger.warning("\(logMessage) \(paneId.uuidString, privacy: .public)")
        if !shellRegistry.hasClientReferences(staleContext.client) {
            trackShellCleanup(
                for: staleContext.serverId,
                reason: "stale pane start"
            ) { [client = staleContext.client] in
                await client.disconnect()
            }
        }
    }
}

#if DEBUG
extension TerminalTabManager {
    func startRuntimeForTesting(paneId: UUID) async {
        guard let paneState = paneStates[paneId] else {
            return
        }

        let server = serverProvider(paneState.serverId)
        let entityId = TerminalEntityID.pane(paneId)
        let runtime: TerminalConnectionRuntime
        if let existing = terminalConnectionRegistry.runtime(for: entityId) {
            runtime = existing
        } else {
            runtime = makeTerminalConnectionRuntime(entityId: entityId, server: server)
            terminalConnectionRegistry.register(runtime, for: entityId, serverId: paneState.serverId)
        }
        await runtime.open(configuration: .testing)
        if await runtime.state == .streaming {
            updatePaneState(paneId, connectionState: .connected)
        }
    }
}
#endif
