import Foundation
import Testing
@testable import Waterm

// Test Context:
// These integration tests protect manager-owned terminal runtime lifecycle
// ordering. They use real manager singletons with injected runtime clients and
// delayed runner tasks, so failures usually mean runtime ownership, close
// awaiting, or stale shell-generation rejection changed. Update only when the
// intended application-layer runtime contract changes.

@Suite(.serialized)
@MainActor
struct ConnectionRuntimeRunnerLifecycleTests {
    private func makeServer(
        id: UUID = UUID(),
        workspaceId: UUID = UUID(),
        name: String = "Test",
        connectionMode: SSHConnectionMode = .cloudflare
    ) -> Server {
        Server(
            id: id,
            workspaceId: workspaceId,
            name: name,
            host: "ssh.example.com",
            username: "root",
            connectionMode: connectionMode
        )
    }

    private func makeCredentials(serverId: UUID) -> ServerCredentials {
        ServerCredentials(
            serverId: serverId,
            password: nil,
            privateKey: nil,
            publicKey: nil,
            passphrase: nil,
            cloudflareClientID: nil,
            cloudflareClientSecret: nil
        )
    }

    private func withCleanConnectionManager(
        _ body: @MainActor (ConnectionSessionManager) async throws -> Void
    ) async rethrows {
        let manager = ConnectionSessionManager.shared
        await manager.resetForTesting()
        manager.setRejectedShellCleanupOperationForTesting {}
        do {
            try await body(manager)
            await manager.resetForTesting()
        } catch {
            await manager.resetForTesting()
            throw error
        }
    }

    private func withCleanTabManager(
        _ body: @MainActor (TerminalTabManager) async throws -> Void
    ) async rethrows {
        let manager = TerminalTabManager.shared
        await manager.resetForTesting()
        manager.setRejectedShellCleanupOperationForTesting {}
        do {
            try await body(manager)
            await manager.resetForTesting()
        } catch {
            await manager.resetForTesting()
            throw error
        }
    }

    @Test
    func tabManagerPaneInputResizeAndCloseUseManagerOwnedRuntime() async {
        await withCleanTabManager { manager in
            // Given a split-pane tab and a fake runtime client owned by the
            // application manager, not by the SwiftUI pane coordinator.
            let serverId = UUID()
            let tab = TerminalTab(serverId: serverId, title: "Runtime Pane")
            let fake = RuntimeRecordingClient()
            manager.tabsByServer[serverId] = [tab]
            manager.selectedTabByServer[serverId] = tab.id
            manager.paneStates[tab.rootPaneId] = TerminalPaneState(
                paneId: tab.rootPaneId,
                tabId: tab.id,
                serverId: serverId
            )
            manager.setTerminalConnectionClientFactoryForTesting { _, _ in fake }

            // When the manager starts the pane runtime, forwards terminal I/O,
            // and closes the pane.
            await manager.startRuntimeForTesting(paneId: tab.rootPaneId)
            await manager.sendInput(Data("ls\n".utf8), toPane: tab.rootPaneId)
            await manager.resizePane(tab.rootPaneId, cols: 100, rows: 32)
            await manager.closePaneAndWait(tab: tab, paneId: tab.rootPaneId)

            // Then all SSH-facing work is serialized through manager-owned
            // runtime state, including close teardown before the close returns.
            let events = await fake.events
            #expect(events == ["connect", "startShell", "write", "resize", "closeShell", "disconnect"])
            #expect(manager.remoteConnectionLease(for: tab.rootPaneId) == nil)
            #expect(manager.paneStates[tab.rootPaneId] == nil)
        }
    }

    @Test
    func connectionManagerConfiguredRuntimeUsesInjectedFactory() async {
        await withCleanConnectionManager { manager in
            // Given a session whose runtime is configured through the
            // application manager and a fake client factory.
            let server = makeServer(connectionMode: .standard)
            let session = ConnectionSession(
                serverId: server.id,
                title: server.name,
                connectionState: .connecting
            )
            let fake = RuntimeRecordingClient()
            manager.sessions = [session]
            manager.setTerminalConnectionClientFactoryForTesting { entityId, factoryServer in
                #expect(entityId == .session(session.id))
                #expect(factoryServer?.id == server.id)
                return fake
            }

            // When the production configure path prepares and starts a runtime.
            manager.configureRuntime(
                for: session.id,
                server: server,
                credentials: makeCredentials(serverId: server.id),
                onProcessExit: {}
            )

            // Then the manager exposes a centralized runtime for that session
            // and the runtime uses the injected factory rather than constructing
            // a manager-local SSHClient.
            #expect(
                manager.hasTerminalConnectionRuntimeForTesting(.session(session.id)),
                "Configured sessions should be represented by TerminalConnectionRuntime."
            )
            await manager.startRuntimeForTesting(sessionId: session.id)

            let events = await fake.events
            #expect(events == ["connect", "startShell"])
            #expect(manager.sessionState(for: session.id) == .connected)
        }
    }

    @Test
    func connectionManagerCloseSessionAndWaitAwaitsStoredRunnerTask() async {
        await withCleanConnectionManager { manager in
            // Given a session with a configured production-style runtime and a
            // stored runner task whose finish path is deliberately delayed.
            let server = makeServer(connectionMode: .standard)
            let session = ConnectionSession(
                serverId: server.id,
                title: server.name,
                connectionState: .connected
            )
            let runnerGate = RuntimeRunnerTaskGate()
            manager.sessions = [session]
            manager.configureRuntime(
                for: session.id,
                server: server,
                credentials: makeCredentials(serverId: server.id),
                onProcessExit: {}
            )
            await manager.setRuntimeShellTaskForTesting(
                sessionId: session.id,
                Task {
                    await runnerGate.waitForRelease()
                    await runnerGate.markRunnerFinished()
                }
            )

            // When the application close-and-wait API runs before the runner
            // task has released its cleanup path.
            let closeTask = Task {
                await manager.closeSessionAndWait(session)
                await runnerGate.markCloseReturned()
            }
            try? await Task.sleep(for: .milliseconds(20))

            // Then close-and-wait must still be waiting on the runner task.
            #expect(
                await !runnerGate.closeReturned,
                "closeSessionAndWait must not return while the stored runner task is still finishing."
            )

            await runnerGate.release()
            await closeTask.value
            #expect(
                await runnerGate.runnerFinished,
                "The delayed runner task should finish before closeSessionAndWait returns."
            )
        }
    }

    @Test
    func connectionManagerLateRuntimeShellCallbackCannotUpdateClosedGeneration() async {
        await withCleanConnectionManager { manager in
            // Given a shell start that belongs to an older session generation.
            let server = makeServer(connectionMode: .standard)
            let session = ConnectionSession(
                serverId: server.id,
                title: server.name,
                connectionState: .connecting
            )
            let staleClient = SSHClient()
            let staleShellId = UUID()
            manager.sessions = [session]
            let staleGeneration = manager.beginShellStartForTesting(
                sessionId: session.id,
                serverId: server.id,
                client: staleClient
            )
            manager.closeShellRegistrationForTesting(sessionId: session.id)

            // When the old runner reports a late shell callback.
            let accepted = manager.completeRuntimeShellStartForTesting(
                sessionId: session.id,
                client: staleClient,
                shellId: staleShellId,
                serverId: server.id,
                generation: staleGeneration
            )

            // Then the stale callback cannot register a shell or move UI state
            // back to connected for the closed generation.
            #expect(!accepted)
            #expect(manager.shellId(for: session.id) == nil)
            #expect(manager.sessionState(for: session.id) == .connecting)
        }
    }

    @Test
    func tabManagerConfiguredRuntimeUsesInjectedFactory() async {
        await withCleanTabManager { manager in
            // Given a pane whose runtime is configured through the application
            // manager and a fake client factory.
            let server = makeServer(connectionMode: .standard)
            let tab = TerminalTab(serverId: server.id, title: server.name)
            let fake = RuntimeRecordingClient()
            manager.tabsByServer[server.id] = [tab]
            manager.selectedTabByServer[server.id] = tab.id
            manager.paneStates[tab.rootPaneId] = TerminalPaneState(
                paneId: tab.rootPaneId,
                tabId: tab.id,
                serverId: server.id
            )
            manager.setTerminalConnectionClientFactoryForTesting { entityId, factoryServer in
                #expect(entityId == .pane(tab.rootPaneId))
                #expect(factoryServer?.id == server.id)
                return fake
            }

            // When the production configure path prepares and starts a runtime.
            manager.configureRuntime(
                forPane: tab.rootPaneId,
                server: server,
                credentials: makeCredentials(serverId: server.id),
                onProcessExit: {}
            )

            // Then the manager exposes a centralized runtime for that pane and
            // the runtime uses the injected factory.
            #expect(
                manager.hasTerminalConnectionRuntimeForTesting(.pane(tab.rootPaneId)),
                "Configured panes should be represented by TerminalConnectionRuntime."
            )
            await manager.startRuntimeForTesting(paneId: tab.rootPaneId)

            let events = await fake.events
            #expect(events == ["connect", "startShell"])
            #expect(manager.paneStates[tab.rootPaneId]?.connectionState == .connected)
        }
    }

    @Test
    func tabManagerClosePaneAndWaitAwaitsStoredRunnerTask() async {
        await withCleanTabManager { manager in
            // Given a pane with a configured production-style runtime and a
            // stored runner task whose finish path is deliberately delayed.
            let server = makeServer(connectionMode: .standard)
            let tab = TerminalTab(serverId: server.id, title: server.name)
            let runnerGate = RuntimeRunnerTaskGate()
            manager.tabsByServer[server.id] = [tab]
            manager.selectedTabByServer[server.id] = tab.id
            var paneState = TerminalPaneState(
                paneId: tab.rootPaneId,
                tabId: tab.id,
                serverId: server.id
            )
            paneState.connectionState = .connected
            manager.paneStates[tab.rootPaneId] = paneState
            manager.configureRuntime(
                forPane: tab.rootPaneId,
                server: server,
                credentials: makeCredentials(serverId: server.id),
                onProcessExit: {}
            )
            await manager.setRuntimeShellTaskForTesting(
                paneId: tab.rootPaneId,
                Task {
                    await runnerGate.waitForRelease()
                    await runnerGate.markRunnerFinished()
                }
            )

            // When the application close-and-wait API runs before the runner
            // task has released its cleanup path.
            let closeTask = Task {
                await manager.closePaneAndWait(tab: tab, paneId: tab.rootPaneId)
                await runnerGate.markCloseReturned()
            }
            try? await Task.sleep(for: .milliseconds(20))

            // Then close-and-wait must still be waiting on the runner task.
            #expect(
                await !runnerGate.closeReturned,
                "closePaneAndWait must not return while the stored runner task is still finishing."
            )

            await runnerGate.release()
            await closeTask.value
            #expect(
                await runnerGate.runnerFinished,
                "The delayed runner task should finish before closePaneAndWait returns."
            )
        }
    }

    @Test
    func tabManagerReconnectClearsRuntimeShellIdBeforeNextStart() async {
        await withCleanTabManager { manager in
            // Given a pane whose shell registry and manager-owned runtime both
            // still point at the shell that is about to be reconnected.
            let server = makeServer(connectionMode: .standard)
            let tab = TerminalTab(serverId: server.id, title: server.name)
            let staleClient = SSHClient()
            let staleShellId = UUID()
            manager.tabsByServer[server.id] = [tab]
            manager.selectedTabByServer[server.id] = tab.id
            manager.paneStates[tab.rootPaneId] = TerminalPaneState(
                paneId: tab.rootPaneId,
                tabId: tab.id,
                serverId: server.id
            )
            manager.configureRuntime(
                forPane: tab.rootPaneId,
                server: server,
                credentials: makeCredentials(serverId: server.id),
                onProcessExit: {}
            )
            manager.registerSSHClient(
                staleClient,
                shellId: staleShellId,
                for: tab.rootPaneId,
                serverId: server.id,
                skipTmuxLifecycle: true
            )
            await manager.paneRuntimes[tab.rootPaneId]?.runtime.setShellId(staleShellId)

            // When reconnect tears down the old pane shell.
            await manager.reconnectPane(tab.rootPaneId)

            // Then neither shell registry nor runtime currentShellId may keep
            // the stale shell, or the next surface attach can skip starting a
            // fresh shell and mark the pane connected too early.
            #expect(manager.shellId(for: tab.rootPaneId) == nil)
            #expect(await manager.paneRuntimes[tab.rootPaneId]?.runtime.currentShellId() == nil)
            #expect(manager.paneStates[tab.rootPaneId]?.connectionState == .reconnecting(attempt: 1))
        }
    }

    @Test
    func connectionManagerReconnectClearsRuntimeShellIdBeforeNextStart() async throws {
        try await withCleanConnectionManager { manager in
            // Given a session whose shell registry and manager-owned runtime
            // both still point at the shell that is about to be reconnected.
            let server = makeServer(connectionMode: .standard)
            let session = ConnectionSession(
                serverId: server.id,
                title: server.name,
                connectionState: .connected
            )
            let staleClient = SSHClient()
            let staleShellId = UUID()
            manager.sessions = [session]
            manager.setServerProviderForTesting { requestedId in
                requestedId == server.id ? server : nil
            }
            manager.configureRuntime(
                for: session.id,
                server: server,
                credentials: makeCredentials(serverId: server.id),
                onProcessExit: {}
            )
            manager.registerSSHClient(
                staleClient,
                shellId: staleShellId,
                for: session.id,
                serverId: server.id,
                skipTmuxLifecycle: true
            )
            await manager.sessionRuntimes[session.id]?.runtime.setShellId(staleShellId)

            // When reconnect tears down the old session shell.
            try await manager.reconnect(session: session)

            // Then neither shell registry nor runtime currentShellId may keep
            // the stale shell, or the next surface attach can skip starting a
            // fresh shell and mark the session connected too early.
            #expect(manager.shellId(for: session.id) == nil)
            #expect(await manager.sessionRuntimes[session.id]?.runtime.currentShellId() == nil)
            #expect(manager.sessionState(for: session.id) == .reconnecting(attempt: 1))
        }
    }

    @Test
    func tabManagerLateRuntimeShellCallbackCannotUpdateClosedGeneration() async {
        await withCleanTabManager { manager in
            // Given a shell start that belongs to an older pane generation.
            let server = makeServer(connectionMode: .standard)
            let tab = TerminalTab(serverId: server.id, title: server.name)
            let staleClient = SSHClient()
            let staleShellId = UUID()
            manager.tabsByServer[server.id] = [tab]
            manager.selectedTabByServer[server.id] = tab.id
            manager.paneStates[tab.rootPaneId] = TerminalPaneState(
                paneId: tab.rootPaneId,
                tabId: tab.id,
                serverId: server.id
            )
            let staleGeneration = manager.beginShellStartForTesting(
                paneId: tab.rootPaneId,
                serverId: server.id,
                client: staleClient
            )
            manager.closeShellRegistrationForTesting(paneId: tab.rootPaneId)

            // When the old runner reports a late shell callback.
            let accepted = manager.completeRuntimeShellStartForTesting(
                paneId: tab.rootPaneId,
                client: staleClient,
                shellId: staleShellId,
                serverId: server.id,
                generation: staleGeneration
            )

            // Then the stale callback cannot register a shell or move UI state
            // back to connected for the closed generation.
            #expect(!accepted)
            #expect(manager.shellId(for: tab.rootPaneId) == nil)
            #expect(
                manager.paneStates[tab.rootPaneId]?.connectionState != .connected,
                "A stale pane runner callback must not move the pane back to connected."
            )
        }
    }
}

private actor RuntimeRunnerTaskGate {
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var isReleased = false
    private(set) var runnerFinished = false
    private(set) var closeReturned = false

    func waitForRelease() async {
        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func release() {
        isReleased = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func markRunnerFinished() {
        runnerFinished = true
    }

    func markCloseReturned() {
        closeReturned = true
    }
}

private actor RuntimeRecordingClient: TerminalConnectionClient {
    private(set) var events: [String] = []
    private let shellId = UUID()

    func connect() async throws {
        events.append("connect")
    }

    func startShell() async throws -> UUID {
        events.append("startShell")
        return shellId
    }

    func closeShell(_ shellId: UUID) async {
        events.append("closeShell")
    }

    func disconnect() async {
        events.append("disconnect")
    }

    func write(_ data: Data, to shellId: UUID) async throws {
        events.append("write")
    }

    func resize(cols: Int, rows: Int, for shellId: UUID) async throws {
        events.append("resize")
    }
}
