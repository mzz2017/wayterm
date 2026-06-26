import Foundation
import os.log

extension ConnectionSessionManager {
    @discardableResult
    func registerSSHClient(
        _ client: SSHClient,
        shellId: UUID,
        for sessionId: UUID,
        serverId: UUID,
        transport: ShellTransport = .ssh,
        fallbackReason: MoshFallbackReason? = nil,
        skipTmuxLifecycle: Bool = false
    ) -> Bool {
        registerSSHClient(
            client,
            shellId: shellId,
            for: sessionId,
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
        for sessionId: UUID,
        serverId: UUID,
        transport: ShellTransport = .ssh,
        fallbackReason: MoshFallbackReason? = nil,
        generation: SSHShellRegistry.Generation?,
        skipTmuxLifecycle: Bool = false
    ) -> Bool {
        guard sessionWithID(sessionId) != nil else {
            logger.warning("Ignoring shell registration for missing session [sessionId: \(sessionId.uuidString, privacy: .public), serverId: \(serverId.uuidString, privacy: .public)]")
            trackShellCleanup(
                for: serverId,
                reason: "missing session shell"
            ) { [client, shellId] in
                await client.closeShell(shellId)
                await client.disconnect()
            }
            return false
        }

        let registerResult = shellRegistry.register(
            client: client,
            shellId: shellId,
            for: sessionId,
            serverId: serverId,
            transport: transport,
            fallbackReason: fallbackReason,
            generation: generation
        )

        if let stale = registerResult.staleIncomingShell {
            logger.warning("Ignoring stale shell registration [sessionId: \(sessionId.uuidString, privacy: .public), serverId: \(serverId.uuidString, privacy: .public)]")
            trackShellCleanup(
                for: serverId,
                reason: "rejected session shell"
            ) { [client = stale.client, shellId = stale.shellId] in
                await client.closeShell(shellId)
                await client.disconnect()
            }
            return false
        }

        if let replaced = registerResult.replacedShell {
            trackShellCleanup(
                for: serverId,
                reason: "replaced session shell"
            ) { [client = replaced.client, shellId = replaced.shellId] in
                await client.closeShell(shellId)
            }
        }

        setTransport(transport, fallbackReason: fallbackReason, for: sessionId)
        terminalsNeedingReconnectReset.remove(sessionId)

        if !skipTmuxLifecycle {
            Task { [weak self] in
                await self?.handleTmuxLifecycle(sessionId: sessionId, serverId: serverId, client: client, shellId: shellId)
            }
        }
        return true
    }

    func sshClient(for session: ConnectionSession) -> SSHClient? {
        shellRegistry.client(for: session.id)
    }

    func remoteConnectionLease(forSessionId sessionId: UUID) -> RemoteConnectionLease? {
        sshClient(forSessionId: sessionId).map {
            RemoteConnectionLease(client: $0, ownership: .borrowed)
        }
    }

    func shellId(for session: ConnectionSession) -> UUID? {
        shellRegistry.shellId(for: session.id)
    }

    func shellId(for sessionId: UUID) -> UUID? {
        shellRegistry.shellId(for: sessionId)
    }

    /// Returns true only for the first caller while no live shell exists for the session.
    func tryBeginShellStart(for sessionId: UUID, client: SSHClient) -> Bool {
        beginShellStart(for: sessionId, client: client)?.started == true
    }

    func beginShellStart(for sessionId: UUID, client: SSHClient) -> SSHShellRegistry.StartResult? {
        guard let serverId = sessionWithID(sessionId)?.serverId else {
            return nil
        }

        let startResult = shellRegistry.tryBeginStart(
            for: sessionId,
            serverId: serverId,
            client: client
        )

        handleStaleShellStartContext(
            startResult.staleContext,
            logMessage: "Recovered stale session shell-start lock for",
            sessionId: sessionId
        )
        return startResult
    }

    func finishShellStart(for sessionId: UUID, client: SSHClient, generation: SSHShellRegistry.Generation? = nil) {
        shellRegistry.finishStart(for: sessionId, client: client, generation: generation)
    }

    func isShellStartInFlight(for sessionId: UUID) -> Bool {
        let result = shellRegistry.isStartInFlight(for: sessionId)
        handleStaleShellStartContext(
            result.staleContext,
            logMessage: "Cleared stale session shell-start in-flight flag for",
            sessionId: sessionId
        )
        return result.inFlight
    }

    func sharedStatsLease(for serverId: UUID) -> RemoteConnectionLease? {
        sharedStatsClient(for: serverId).map {
            RemoteConnectionLease(client: $0, ownership: .borrowed)
        }
    }

    func configureRuntime(
        for sessionId: UUID,
        server: Server,
        credentials: ServerCredentials,
        onProcessExit: @escaping () -> Void
    ) {
        if let runtime = sessionRuntimes[sessionId] {
            runtime.server = server
            runtime.credentials = credentials
            runtime.onProcessExit = onProcessExit
            return
        }

        let entityId = TerminalEntityID.session(sessionId)
        let runtime = makeTerminalConnectionRuntime(entityId: entityId, server: server)
        terminalConnectionRegistry.register(runtime, for: entityId, serverId: server.id)
        sessionRuntimes[sessionId] = SessionRuntimeState(
            sessionId: sessionId,
            server: server,
            credentials: credentials,
            runtime: runtime,
            onProcessExit: onProcessExit
        )
    }

    func startRuntimeIfNeeded(for sessionId: UUID, terminal: GhosttyTerminalView) async {
        guard let runtime = runtimeStateForStarting(sessionId: sessionId) else { return }
        await startRuntimeIfNeeded(runtime, terminal: terminal)
    }

    func registeredShellRoute(for sessionId: UUID) -> (client: SSHClient, shellId: UUID)? {
        guard let client = sshClient(forSessionId: sessionId),
              let shellId = shellId(for: sessionId) else {
            return nil
        }
        return (client: client, shellId: shellId)
    }

    func suspendRuntime(for sessionId: UUID) async {
        guard let runtime = sessionRuntimes[sessionId] else { return }
        await runtime.runtime.suspend()
    }

    func cancelRuntime(
        for sessionId: UUID,
        mode: ShellTeardownMode,
        cleanupTerminal: Bool
    ) async {
        let runtime = sessionRuntimes[sessionId]
        await runtime?.runtime.cancelShellTask()
        let shellId = await runtime?.runtime.clearShellId()

        if cleanupTerminal {
            terminalSurfaceRegistry.removeSurface(for: .session(sessionId), cleanup: true)
        }

        guard let runtime else { return }
        if let shellId {
            await runtime.runtime.closeRunnerShell(shellId)
        }
        if mode == .fullDisconnect {
            await runtime.runtime.disconnectRunnerClientAndClear()
            sessionRuntimes.removeValue(forKey: sessionId)
            terminalConnectionRegistry.discardRuntime(for: .session(sessionId))
        }
    }

    private func sshClient(forSessionId sessionId: UUID) -> SSHClient? {
        shellRegistry.client(for: sessionId)
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
        if let selectedId = selectedSessionId,
           let selectedSession = sessionWithID(selectedId),
           selectedSession.serverId == serverId,
           let registration = shellRegistry.registration(for: selectedSession.id) {
            return registration
        }

        if let anySession = firstSession(for: serverId),
           let registration = shellRegistry.registration(for: anySession.id) {
            return registration
        }

        return shellRegistry.firstRegistration(for: serverId)
    }

    private func sshClient(for serverId: UUID) -> SSHClient? {
        preferredSSHClient(for: serverId, allowPendingStart: true)
    }

    private func activeSSHClient(for serverId: UUID) -> SSHClient? {
        preferredSSHClient(for: serverId, allowPendingStart: false)
    }

    private func sharedStatsClient(for serverId: UUID) -> SSHClient? {
        if let liveSession = registryLiveSession(for: serverId) {
            guard let registration = shellRegistry.registration(for: liveSession.id),
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

    private func registryLiveSession(for serverId: UUID) -> ConnectionSession? {
        let liveEntityIDs = terminalConnectionRegistry.openingOrStreamingEntityIDs(for: serverId)
        if let selected = selectedSession(for: serverId),
           liveEntityIDs.contains(.session(selected.id)) {
            return selected
        }

        return sessions.first {
            $0.serverId == serverId && liveEntityIDs.contains(.session($0.id))
        }
    }

    private func selectedSession(for serverId: UUID) -> ConnectionSession? {
        if let selectedSessionId = selectedSessionByServer[serverId] {
            return sessionWithID(selectedSessionId)
        }

        guard let selectedSessionId,
              let session = sessionWithID(selectedSessionId),
              session.serverId == serverId else {
            return nil
        }

        return session
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

    private func runtimeStateForStarting(sessionId: UUID) -> SessionRuntimeState? {
        if let runtime = sessionRuntimes[sessionId] {
            return runtime
        }

        guard let session = sessionWithID(sessionId),
              let server = ServerManager.shared.servers.first(where: { $0.id == session.serverId }) else {
            updateSessionState(sessionId, to: .failed("Server not found"))
            return nil
        }

        do {
            let credentials = try KeychainManager.shared.getCredentials(for: server)
            configureRuntime(for: sessionId, server: server, credentials: credentials, onProcessExit: {})
            return sessionRuntimes[sessionId]
        } catch {
            updateSessionState(sessionId, to: .failed(error.localizedDescription))
            return nil
        }
    }

    private func startRuntimeIfNeeded(_ runtime: SessionRuntimeState, terminal: any TerminalConnectionSurface) async {
        let sessionId = runtime.sessionId

        if await runtime.runtime.hasShellTask() {
            logger.debug("Ignoring duplicate start request for session \(sessionId.uuidString, privacy: .public)")
            return
        }

        if let existingShellId = shellId(for: sessionId) {
            await runtime.runtime.setShellId(existingShellId)
            updateSessionState(sessionId, to: .connected)
            logger.debug("Reusing existing shell for session \(sessionId.uuidString, privacy: .public)")
            return
        }

        if await runtime.runtime.currentShellId() != nil {
            updateSessionState(sessionId, to: .connected)
            return
        }

        let sshClient = await runtime.runtime.runnerClient()
        guard let startResult = beginShellStart(for: sessionId, client: sshClient),
              startResult.started else {
            if shellId(for: sessionId) != nil {
                updateSessionState(sessionId, to: .connected)
            }
            logger.debug("Shell start already in progress for session \(sessionId.uuidString, privacy: .public)")
            return
        }

        let server = runtime.server
        let credentials = runtime.credentials
        let onProcessExit = runtime.onProcessExit
        let logger = self.logger
        let shellGeneration = startResult.generation

        let shellTask = Task.detached(priority: .userInitiated) { [weak terminal] in
            defer {
                Task { @MainActor in
                    ConnectionSessionManager.shared.finishShellStart(
                        for: sessionId,
                        client: sshClient,
                        generation: shellGeneration
                    )
                    if let runtime = ConnectionSessionManager.shared.sessionRuntimes[sessionId]?.runtime {
                        await runtime.clearShellTask(ifUsing: sshClient)
                    }
                }
            }

            guard let terminal else { return }
            await TerminalConnectionRunner.run(
                server: server,
                credentials: credentials,
                sshClient: sshClient,
                terminal: terminal,
                logger: logger,
                onAttempt: { attempt in
                    if attempt == 1 {
                        ConnectionSessionManager.shared.updateSessionState(sessionId, to: .connecting)
                    } else {
                        ConnectionSessionManager.shared.updateSessionState(sessionId, to: .reconnecting(attempt: attempt))
                    }
                },
                startupPlan: {
                    await ConnectionSessionManager.shared.tmuxStartupPlan(
                        for: sessionId,
                        serverId: server.id,
                        client: sshClient
                    )
                },
                registerShell: { shell, skipTmuxLifecycle in
                    let accepted = ConnectionSessionManager.shared.registerSSHClient(
                        sshClient,
                        shellId: shell.id,
                        for: sessionId,
                        serverId: server.id,
                        transport: shell.transport,
                        fallbackReason: shell.fallbackReason,
                        generation: shellGeneration,
                        skipTmuxLifecycle: skipTmuxLifecycle
                    )
                    guard accepted else { return false }
                    await ConnectionSessionManager.shared.sessionRuntimes[sessionId]?.runtime.setShellId(shell.id)
                    ConnectionSessionManager.shared.updateSessionState(sessionId, to: .connected)
                    return true
                },
                onBeforeShellStart: { cols, rows in
                    await ConnectionSessionManager.shared.sessionRuntimes[sessionId]?.runtime.updateLastSize(cols: cols, rows: rows)
                },
                onShellStarted: { _, shellId in
                    await ConnectionSessionManager.shared.applyWorkingDirectoryIfNeeded(
                        for: sessionId,
                        client: sshClient,
                        shellId: shellId
                    )
                },
                onTitleChange: { title in
                    ConnectionSessionManager.shared.updateSessionTitle(sessionId, rawTitle: title)
                },
                shouldContinueStreaming: { data, terminal in
                    let sessionExists = ConnectionSessionManager.shared.sessions.contains { $0.id == sessionId }
                    guard sessionExists else { return false }
                    terminal.writeConnectionOutput(data)
                    return true
                },
                shouldResetClient: { sshError in
                    switch sshError {
                    case .notConnected, .connectionFailed, .socketError, .timeout, .libssh2:
                        return true
                    case .channelOpenFailed, .shellRequestFailed:
                        let hasOtherRegistrations = await ConnectionSessionManager.shared.hasOtherRegistrations(
                            using: sshClient,
                            excluding: sessionId
                        )
                        return !hasOtherRegistrations
                    case .authenticationFailed, .tailscaleAuthenticationNotAccepted, .cloudflareConfigurationRequired, .cloudflareAuthenticationFailed, .cloudflareTunnelFailed, .hostKeyVerificationFailed, .moshServerMissing, .moshBootstrapFailed, .moshSessionFailed, .unknown:
                        return false
                    }
                },
                onProcessExit: {
                    onProcessExit()
                },
                onFailure: { error, terminal in
                    let errorMsg = "\r\n\u{001B}[31mSSH Error: \(error.localizedDescription)\u{001B}[0m\r\n"
                    if let data = errorMsg.data(using: .utf8) {
                        terminal.writeConnectionOutput(data)
                    }
                    ConnectionSessionManager.shared.updateSessionState(sessionId, to: .failed(error.localizedDescription))
                }
            )
        }
        await runtime.runtime.setShellTask(shellTask)
    }

    private func applyWorkingDirectoryIfNeeded(
        for sessionId: UUID,
        client: SSHClient,
        shellId: UUID
    ) async {
        let cwd: String? = await MainActor.run {
            guard ConnectionSessionManager.shared.shouldApplyWorkingDirectory(for: sessionId) else { return nil }
            return ConnectionSessionManager.shared.workingDirectory(for: sessionId)
        }
        guard let cwd else { return }
        let environment = await client.remoteEnvironment()
        guard environment.shellProfile.family != .unknown else { return }
        guard let payload = RemoteTerminalBootstrap.directoryChangeCommand(
            for: cwd,
            environment: environment
        ).data(using: .utf8) else {
            return
        }
        try? await client.write(payload, to: shellId)
    }

    private func handleStaleShellStartContext(
        _ staleContext: SSHShellRegistry.StartContext?,
        logMessage: StaticString,
        sessionId: UUID
    ) {
        guard let staleContext else { return }

        logger.warning("\(logMessage) \(sessionId.uuidString, privacy: .public)")
        if !shellRegistry.hasClientReferences(staleContext.client) {
            trackShellCleanup(
                for: staleContext.serverId,
                reason: "stale session start"
            ) { [client = staleContext.client] in
                await client.disconnect()
            }
        }
    }
}

#if DEBUG
extension ConnectionSessionManager {
    func startRuntimeForTesting(sessionId: UUID) async {
        guard let session = sessionWithID(sessionId) else {
            return
        }

        let server = ServerManager.shared.servers.first { $0.id == session.serverId }
        let entityId = session.terminalEntityId
        let runtime: TerminalConnectionRuntime
        if let existing = terminalConnectionRegistry.runtime(for: entityId) {
            runtime = existing
        } else {
            runtime = makeTerminalConnectionRuntime(entityId: entityId, server: server)
            terminalConnectionRegistry.register(runtime, for: entityId, serverId: session.serverId)
        }
        await runtime.open(configuration: .testing)
        if await runtime.state == .streaming {
            updateSessionState(sessionId, to: .connected)
        }
    }
}
#endif
