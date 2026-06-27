import Foundation
import Testing
@testable import VVTerm

// Test Context:
// These integration tests protect terminal connection lifecycle ordering across
// app-level managers. They intentionally use real manager singletons but avoid
// real network I/O; registered SSHClient instances are never connected. A
// failure usually means a lifecycle invariant changed, such as close/open
// ordering, reconnect guard behavior, watchdog retry ownership, background
// suspend handling, or working-directory restoration. Update these tests only
// when the intended lifecycle contract changes.

@Suite(.serialized)
@MainActor
struct ConnectionLifecycleIntegrationTests {
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

    private func withServerList<T>(
        _ servers: [Server],
        _ body: @MainActor () async throws -> T
    ) async rethrows -> T {
        let serverManager = ServerManager.shared
        let originalServers = serverManager.servers
        serverManager.servers = servers
        defer { serverManager.servers = originalServers }
        return try await body()
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
    func tabManagerWatchdogSchedulingIntentUsesManagerState() async {
        await withCleanTabManager { manager in
            let server = makeServer()
            let tabId = UUID()
            let paneId = UUID()
            var paneState = TerminalPaneState(paneId: paneId, tabId: tabId, serverId: server.id)
            paneState.connectionState = .connecting
            manager.paneStates[paneId] = paneState

            // Given split-pane SwiftUI sends only UI readiness and terminal
            // surface presence to the application layer.
            #expect(
                manager.shouldScheduleConnectWatchdog(
                    forPaneId: paneId,
                    isReady: false,
                    terminalExists: false
                ),
                "Connecting panes should schedule watchdogs through TerminalTabManager."
            )

            // When the pane is connected but the terminal surface is not ready,
            // the manager still owns the connected-without-terminal rule.
            manager.updatePaneState(paneId, connectionState: .connected)
            #expect(
                manager.shouldScheduleConnectWatchdog(
                    forPaneId: paneId,
                    isReady: false,
                    terminalExists: false
                ),
                "Connected panes without a ready terminal should continue watchdog scheduling."
            )

            // Then ready connected panes stop scheduling.
            #expect(
                !manager.shouldScheduleConnectWatchdog(
                    forPaneId: paneId,
                    isReady: true,
                    terminalExists: true
                ),
                "Ready connected panes should not schedule another watchdog."
            )
        }
    }

    @Test
    func tabManagerOwnsConnectWatchdogRetryTask() async {
        await withCleanTabManager { manager in
            let server = makeServer()
            let tabId = UUID()
            let paneId = UUID()
            var paneState = TerminalPaneState(paneId: paneId, tabId: tabId, serverId: server.id)
            paneState.connectionState = .connected
            manager.paneStates[paneId] = paneState
            manager.updatePaneState(paneId, connectionState: .connected)
            var retryCount = 0

            // Given a connected split pane whose terminal surface never became
            // ready, and SwiftUI sends only surface state.
            manager.scheduleConnectWatchdog(
                forPaneId: paneId,
                isReady: false,
                terminalExists: false,
                timeout: .milliseconds(10),
                timeoutMessage: "timeout"
            ) {
                retryCount += 1
            }

            // When the manager-owned watchdog timeout expires.
            try? await Task.sleep(for: .milliseconds(150))

            // Then retry is triggered by TerminalTabManager's task.
            #expect(retryCount == 1)
            #expect(manager.paneStates[paneId]?.connectionState == .disconnected)
        }
    }

    @Test
    func tabManagerReconnectPaneSkipsWhenRegistryRuntimeIsLive() async {
        await withCleanTabManager { manager in
            let serverId = UUID()
            let paneId = UUID()
            manager.paneStates[paneId] = TerminalPaneState(
                paneId: paneId,
                tabId: UUID(),
                serverId: serverId
            )

            // Given a pane with a live manager-owned opening runtime and a stale
            // disconnected display snapshot.
            let client = SSHClient()
            #expect(manager.tryBeginShellStart(for: paneId, client: client))
            manager.updatePaneState(paneId, connectionState: .connecting)
            manager.paneStates[paneId]?.connectionState = .disconnected

            // When split-pane reconnect is requested.
            await manager.reconnectPane(paneId)

            // Then the application layer must not unregister or cancel the live
            // opening runtime just because the UI snapshot is stale.
            #expect(manager.isShellStartInFlight(for: paneId))
        }
    }

    @Test
    func tabManagerReconnectPaneStartsWhenSnapshotIsConnectingButRegistryRuntimeIsInactive() async {
        await withCleanTabManager { manager in
            let serverId = UUID()
            let paneId = UUID()
            var stalePane = TerminalPaneState(
                paneId: paneId,
                tabId: UUID(),
                serverId: serverId
            )
            stalePane.connectionState = .connecting
            manager.paneStates[paneId] = stalePane

            // When a user retry reaches the application layer after the display
            // snapshot says connecting but the runtime registry is inactive.
            await manager.reconnectPane(paneId)

            // Then reconnect is driven by registry liveness, not blocked by the
            // stale connecting snapshot.
            #expect(manager.hasLiveRuntime(forPaneId: paneId))
            if case .reconnecting(let attempt) = manager.paneStates[paneId]?.connectionState {
                #expect(attempt == 1)
            } else {
                Issue.record("Expected pane to enter reconnecting state.")
            }
        }
    }

    @Test
    func tabManagerOpenTabWaitsForRejectedLateShellCleanupBeforeCreatingTab() async throws {
        try await withCleanTabManager { manager in
            let server = makeServer(name: "Tencent", connectionMode: .standard)
            let tab = TerminalTab(serverId: server.id, title: "Closing Pane")
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

            var cleanupFinished = false
            manager.setRejectedShellCleanupOperationForTesting {
                try? await Task.sleep(for: .milliseconds(100))
                cleanupFinished = true
            }

            manager.registerSSHClient(
                staleClient,
                shellId: staleShellId,
                for: tab.rootPaneId,
                serverId: server.id,
                generation: staleGeneration,
                skipTmuxLifecycle: true
            )

            _ = try await manager.openTab(for: server)

            #expect(
                cleanupFinished,
                "Opening another tab must wait for cleanup of a rejected late pane shell."
            )
        }
    }

    @Test
    func tabManagerOpenTabWaitsForManagedTmuxKillBeforeCreatingTab() async throws {
        try await withCleanTabManager { manager in
            let server = makeServer(name: "Tencent", connectionMode: .standard)
            let tab = TerminalTab(serverId: server.id, title: "Managed Tmux")
            manager.tabsByServer[server.id] = [tab]
            manager.selectedTabByServer[server.id] = tab.id
            manager.paneStates[tab.rootPaneId] = TerminalPaneState(
                paneId: tab.rootPaneId,
                tabId: tab.id,
                serverId: server.id
            )
            manager.registerSSHClient(
                SSHClient(),
                shellId: UUID(),
                for: tab.rootPaneId,
                serverId: server.id,
                skipTmuxLifecycle: true
            )

            var killFinished = false
            manager.setTmuxKillOperationForTesting {
                try? await Task.sleep(for: .milliseconds(100))
                killFinished = true
            }

            manager.killTmuxIfNeeded(for: tab.rootPaneId)
            _ = try await manager.openTab(for: server)

            #expect(
                killFinished,
                "Opening another tab must wait for a managed tmux kill task on the same server."
            )
        }
    }

    @Test
    func connectionManagerTracksSelectedSessionPerServer() async {
        await withCleanConnectionManager { manager in
            let serverId = UUID()
            let first = ConnectionSession(
                serverId: serverId,
                title: "First",
                connectionState: .disconnected
            )
            let second = ConnectionSession(
                serverId: serverId,
                title: "Second",
                connectionState: .disconnected
            )

            manager.sessions = [first, second]
            manager.selectSession(second)

            #expect(manager.selectedSessionId == second.id)
            #expect(manager.selectedSessionByServer[serverId] == second.id)
        }
    }

    @Test
    func openConnectionDoesNotSeedWorkingDirectoryFromSelectedDifferentServer() async throws {
        try await withCleanConnectionManager { manager in
            let firstServer = makeServer(name: "First")
            let secondServer = makeServer(name: "Second")

            try await withServerList([firstServer, secondServer]) {
                let firstSession = ConnectionSession(
                    serverId: firstServer.id,
                    title: "First",
                    connectionState: .disconnected,
                    workingDirectory: "/srv/first"
                )
                manager.sessions = [firstSession]
                manager.selectedSessionId = firstSession.id
                manager.selectedSessionByServer[firstServer.id] = firstSession.id

                let newSession = try await manager.openConnection(to: secondServer, forceNew: true)

                #expect(newSession.serverId == secondServer.id)
                #expect(newSession.workingDirectory == nil)
            }
        }
    }

    @Test
    func openConnectionSeedsWorkingDirectoryFromSameServerSession() async throws {
        try await withCleanConnectionManager { manager in
            let firstServer = makeServer(name: "First")
            let secondServer = makeServer(name: "Second")

            try await withServerList([firstServer, secondServer]) {
                let wasPro = StoreManager.shared.isPro
                StoreManager.shared.isPro = true
                defer { StoreManager.shared.isPro = wasPro }

                let firstSession = ConnectionSession(
                    serverId: firstServer.id,
                    title: "First",
                    connectionState: .disconnected,
                    workingDirectory: "/srv/first"
                )
                let secondSession = ConnectionSession(
                    serverId: secondServer.id,
                    title: "Second",
                    connectionState: .disconnected,
                    workingDirectory: "/srv/second"
                )
                manager.sessions = [firstSession, secondSession]
                manager.selectedSessionId = firstSession.id
                manager.selectedSessionByServer[firstServer.id] = firstSession.id
                manager.selectedSessionByServer[secondServer.id] = secondSession.id

                let newSession = try await manager.openConnection(to: secondServer, forceNew: true)

                #expect(newSession.serverId == secondServer.id)
                #expect(newSession.workingDirectory == "/srv/second")
            }
        }
    }

    @Test
    func connectionManagerDisconnectServerLeavesOtherServersConnected() async {
        await withCleanConnectionManager { manager in
            let firstServerId = UUID()
            let secondServerId = UUID()
            let first = ConnectionSession(
                serverId: firstServerId,
                title: "First Server",
                connectionState: .connected
            )
            let second = ConnectionSession(
                serverId: secondServerId,
                title: "Second Server",
                connectionState: .connected
            )

            manager.sessions = [first, second]
            manager.selectedSessionId = first.id
            manager.updateSessionState(first.id, to: .connected)
            manager.updateSessionState(second.id, to: .connected)

            manager.disconnectServer(firstServerId)

            #expect(manager.sessions.count == 1)
            #expect(manager.sessions.first?.id == second.id)
            #expect(manager.selectedSessionId == second.id)
            #expect(manager.connectedServerIds == [secondServerId])
        }
    }

    @Test
    func connectionManagerSuspendAllForBackgroundPreservesTabsAndClearsShells() async {
        await withCleanConnectionManager { manager in
            let serverId = UUID()
            let session = ConnectionSession(
                serverId: serverId,
                title: "Background Session",
                connectionState: .disconnected
            )
            manager.sessions = [session]
            manager.selectedSessionId = session.id
            manager.updateSessionState(session.id, to: .connected)

            let client = SSHClient()
            manager.registerSSHClient(
                client,
                shellId: UUID(),
                for: session.id,
                serverId: serverId,
                skipTmuxLifecycle: true
            )

            var suspendCalls = 0
            manager.registerShellSuspendHandler({
                suspendCalls += 1
            }, for: session.id)

            await manager.suspendAllForBackground()

            #expect(manager.sessions.count == 1)
            #expect(manager.sessions.first?.id == session.id)
            #expect(manager.sessions.first?.connectionState == .disconnected)
            #expect(manager.shellId(for: session.id) == nil)
            #expect(manager.consumeTerminalReconnectReset(for: session.id))
            #expect(manager.connectedServerIds.isEmpty)
            #expect(suspendCalls == 1)
            #expect(!manager.isSuspendingForBackground)
        }
    }

    @Test
    func connectionManagerBackgroundSuspendUsesRegistryActiveStateForReconnectReset() async {
        await withCleanConnectionManager { manager in
            // Given an open tab whose registry runtime state is newer than the
            // domain snapshot retained for UI projection.
            let serverId = UUID()
            let session = ConnectionSession(
                serverId: serverId,
                title: "Registry Active",
                connectionState: .disconnected
            )
            manager.sessions = [session]
            manager.selectedSessionId = session.id

            manager.updateSessionState(session.id, to: .connected)
            manager.sessions[0].connectionState = .disconnected

            // When background suspend runs before foreground reconnect.
            await manager.suspendAllForBackground()

            // Then registry state drives reconnect cleanup even if the
            // persisted tab snapshot already reads disconnected.
            #expect(
                manager.sessions.first?.connectionState == .disconnected,
                "Background suspend should leave the open tab disconnected for foreground reconnect."
            )
            #expect(
                manager.consumeTerminalReconnectReset(for: session.id),
                "A registry-active session must reset its preserved terminal even if the domain state is stale."
            )
            #expect(
                manager.connectedServerIds.isEmpty,
                "Background suspend must clear live server state through the registry."
            )
        }
    }

    @Test
    func connectionManagerHandleShellExitMarksTerminalForReconnectReset() async {
        await withCleanConnectionManager { manager in
            let serverId = UUID()
            let session = ConnectionSession(
                serverId: serverId,
                title: "Reconnect Reset",
                connectionState: .connected
            )
            manager.sessions = [session]
            manager.updateSessionState(session.id, to: .connected)

            let client = SSHClient()
            manager.registerSSHClient(
                client,
                shellId: UUID(),
                for: session.id,
                serverId: serverId,
                skipTmuxLifecycle: true
            )

            manager.handleShellExit(for: session.id)

            #expect(manager.sessions.first?.connectionState == .disconnected)
            #expect(manager.consumeTerminalReconnectReset(for: session.id))
            #expect(!manager.consumeTerminalReconnectReset(for: session.id))
        }
    }

    @Test
    func connectionManagerReconnectDoesNothingWhileBackgroundSuspendIsActive() async {
        await withCleanConnectionManager { manager in
            let server = makeServer(connectionMode: .standard)
            let session = ConnectionSession(
                serverId: server.id,
                title: "Reconnect Guard",
                connectionState: .disconnected
            )

            await withServerList([server]) {
                manager.sessions = [session]
                manager.setBackgroundSuspendInProgressForTesting(true)
                defer { manager.setBackgroundSuspendInProgressForTesting(false) }

                try? await manager.reconnect(session: session)

                #expect(manager.sessions.first?.connectionState == .disconnected)
                #expect(manager.shellId(for: session.id) == nil)
            }
        }
    }

    @Test
    func connectionManagerWatchdogRequestsRetryForConnectedSnapshotWithoutTerminal() async {
        await withCleanConnectionManager { manager in
            let session = ConnectionSession(
                serverId: UUID(),
                title: "Watchdog",
                connectionState: .connected
            )
            manager.sessions = [session]
            manager.updateSessionState(session.id, to: .connected)

            let action = manager.handleConnectWatchdogTimeout(
                forSessionId: session.id,
                isReady: false,
                terminalExists: false,
                timeoutMessage: "Timed out"
            )

            #expect(action == .retry)
            #expect(manager.sessions.first?.connectionState == .disconnected)
        }
    }

    @Test
    func tabManagerWatchdogRequestsRetryForConnectedSnapshotWithoutTerminal() async {
        await withCleanTabManager { manager in
            let paneId = UUID()
            manager.paneStates[paneId] = TerminalPaneState(
                paneId: paneId,
                tabId: UUID(),
                serverId: UUID()
            )
            manager.updatePaneState(paneId, connectionState: .connected)

            let action = manager.handleConnectWatchdogTimeout(
                forPaneId: paneId,
                isReady: false,
                terminalExists: false,
                timeoutMessage: "Timed out"
            )

            #expect(action == .retry)
            #expect(manager.paneStates[paneId]?.connectionState == .disconnected)
        }
    }

    @Test
    func splitPaneUsesLatestTabStateWhenViewTabIsStale() async {
        await withCleanTabManager { manager in
            let wasPro = StoreManager.shared.isPro
            StoreManager.shared.isPro = true
            defer { StoreManager.shared.isPro = wasPro }

            let server = makeServer(connectionMode: .standard)
            let tab = TerminalTab(serverId: server.id, title: server.name)

            manager.paneStates[tab.rootPaneId] = TerminalPaneState(
                paneId: tab.rootPaneId,
                tabId: tab.id,
                serverId: server.id
            )
            manager.tabsByServer[server.id] = [tab]
            manager.selectedTabByServer[server.id] = tab.id

            guard let firstSplitPane = manager.splitHorizontal(tab: tab, paneId: tab.rootPaneId) else {
                Issue.record("First split failed unexpectedly")
                return
            }

            // Intentionally pass a stale snapshot (the original `tab` value) to simulate
            // view-state lag while still targeting a pane created by the first split.
            guard let secondSplitPane = manager.splitVertical(tab: tab, paneId: firstSplitPane) else {
                Issue.record("Second split failed unexpectedly")
                return
            }

            guard let latestTab = manager.tabs(for: server.id).first else {
                Issue.record("Expected tab to exist after split")
                return
            }

            let paneIds = Set(latestTab.allPaneIds)
            #expect(paneIds.contains(tab.rootPaneId))
            #expect(paneIds.contains(firstSplitPane))
            #expect(paneIds.contains(secondSplitPane))
            #expect(paneIds.count == 3)
        }
    }

}
