import Foundation
import Testing
@testable import VVTerm

// Test Context:
// These integration tests protect terminal connection lifecycle ordering across
// app-level managers. They intentionally use real manager singletons but avoid
// real network I/O; registered SSHClient instances are never connected. A
// failure usually means a lifecycle invariant changed, such as stale shell
// registration rejection, close/open ordering, or teardown completion semantics.
// Update these tests only when the intended lifecycle contract changes.

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
        do {
            try await body(manager)
            await manager.resetForTesting()
        } catch {
            await manager.resetForTesting()
            throw error
        }
    }

    @Test
    func connectionManagerRejectsStaleRegistrationFromDifferentClient() async {
        await withCleanConnectionManager { manager in
            let serverId = UUID()
            let session = ConnectionSession(
                serverId: serverId,
                title: "Session A",
                connectionState: .connecting
            )
            manager.sessions = [session]

            let activeClient = SSHClient()
            let staleClient = SSHClient()

            #expect(manager.tryBeginShellStart(for: session.id, client: activeClient))

            manager.registerSSHClient(
                staleClient,
                shellId: UUID(),
                for: session.id,
                serverId: serverId,
                skipTmuxLifecycle: true
            )

            #expect(manager.shellId(for: session.id) == nil)
            #expect(manager.isShellStartInFlight(for: session.id))

            manager.finishShellStart(for: session.id, client: staleClient)
            #expect(manager.isShellStartInFlight(for: session.id))

            manager.finishShellStart(for: session.id, client: activeClient)
            #expect(!manager.isShellStartInFlight(for: session.id))
        }
    }

    @Test
    func connectionManagerRestoredSessionsAreOpenButNotActiveUntilRuntimeStreams() async throws {
        try await withCleanConnectionManager { manager in
            let server = makeServer()
            let sessionId = UUID()
            let snapshot = TestConnectionSessionsSnapshot(
                sessions: [
                    .init(
                        id: sessionId,
                        serverId: server.id,
                        title: server.name,
                        createdAt: Date(),
                        lastActivity: Date(),
                        autoReconnect: true,
                        parentSessionId: nil,
                        workingDirectory: nil,
                        presentationOverrides: nil
                    )
                ],
                selectedSessionId: sessionId,
                serverSelections: [
                    .init(serverId: server.id, selectedSessionId: sessionId, selectedView: "terminal")
                ]
            )
            UserDefaults.standard.set(
                try JSONEncoder().encode(snapshot),
                forKey: "connectionSessionsSnapshot.v1"
            )

            manager.restorePersistedSnapshotForTesting()

            #expect(manager.openServerIds == [server.id], "Restored sessions should keep server navigation open.")
            #expect(manager.activeServerIds.isEmpty, "Restored disconnected sessions must not appear as live transports.")
            #expect(manager.connectedServerIds.isEmpty, "Legacy connected ids should mirror active live transports only.")

            let client = RecordingPaneRuntimeClient()
            manager.setTerminalConnectionClientFactoryForTesting { _, _ in client }
            await manager.startRuntimeForTesting(sessionId: sessionId)

            #expect(manager.activeServerIds == [server.id], "A server becomes active only after its runtime reaches streaming.")
            #expect(manager.connectedServerIds == [server.id], "Legacy connected ids should update when the runtime is streaming.")
        }
    }

    @Test
    func tabManagerRestoredTabsAreOpenButNotActiveUntilRuntimeStreams() async throws {
        try await withCleanTabManager { manager in
            let server = makeServer()
            let tabId = UUID()
            let paneId = UUID()
            let snapshot = TestTerminalTabsSnapshot(
                servers: [
                    .init(
                        serverId: server.id,
                        tabs: [
                            .init(
                                id: tabId,
                                serverId: server.id,
                                title: server.name,
                                createdAt: Date(),
                                layout: nil,
                                focusedPaneId: paneId,
                                rootPaneId: paneId,
                                panePresentationOverrides: nil
                            )
                        ],
                        selectedTabId: tabId,
                        selectedView: "terminal"
                    )
                ]
            )
            UserDefaults.standard.set(
                try JSONEncoder().encode(snapshot),
                forKey: "terminalTabsSnapshot.v1"
            )

            manager.restorePersistedSnapshotForTesting()

            #expect(manager.openServerIds == [server.id], "Restored tabs should keep server navigation open.")
            #expect(manager.activeServerIds.isEmpty, "Restored panes must not appear as live transports before streaming.")
            #expect(manager.connectedServerIds.isEmpty, "Legacy connected ids should mirror active live transports only.")

            let client = RecordingPaneRuntimeClient()
            manager.setTerminalConnectionClientFactoryForTesting { _, _ in client }
            await manager.startRuntimeForTesting(paneId: paneId)

            #expect(manager.activeServerIds == [server.id], "A server becomes active only after a pane runtime reaches streaming.")
            #expect(manager.connectedServerIds == [server.id], "Legacy connected ids should update when the pane runtime is streaming.")
        }
    }

    @Test
    func connectionManagerActiveServersComeFromRegistryNotDomainSessionState() async {
        await withCleanConnectionManager { manager in
            let server = makeServer()
            let session = ConnectionSession(
                serverId: server.id,
                title: server.name,
                connectionState: .connected
            )

            manager.sessions = [session]

            #expect(
                manager.activeServerIds.isEmpty,
                "A stale domain session state must not make a server active without a streaming runtime in the registry."
            )
        }
    }

    @Test
    func connectionManagerActiveSessionsComeFromRegistryNotDomainSessionState() async {
        await withCleanConnectionManager { manager in
            let server = makeServer()
            let staleDomainSession = ConnectionSession(
                serverId: server.id,
                title: "Stale Domain Connected",
                connectionState: .connected
            )
            let registryLiveSession = ConnectionSession(
                serverId: server.id,
                title: "Registry Live",
                connectionState: .disconnected
            )

            manager.sessions = [staleDomainSession, registryLiveSession]
            manager.updateSessionState(registryLiveSession.id, to: .connected)
            manager.sessions[1].connectionState = .disconnected

            #expect(
                manager.activeSessions.map(\.id) == [registryLiveSession.id],
                "Active sessions should come from registry runtime state, not stale domain snapshots."
            )
        }
    }

    @Test
    func connectionManagerRefreshesLiveActivityWithRegistryActiveSessionsOnly() async {
        await withCleanConnectionManager { manager in
            let server = makeServer()
            let staleDomainSession = ConnectionSession(
                serverId: server.id,
                title: "Stale Domain Connected",
                connectionState: .connected
            )
            var refreshedSessionIds: [[UUID]] = []
            manager.liveActivityRefresh = { snapshots in
                refreshedSessionIds.append(snapshots.map(\.sessionId))
            }

            manager.sessions = [staleDomainSession]

            #expect(
                refreshedSessionIds.last == [],
                "Live Activity refreshes must ignore stale domain connected snapshots without registry runtime."
            )

            manager.updateSessionState(staleDomainSession.id, to: .connected)

            #expect(
                refreshedSessionIds.last == [staleDomainSession.id],
                "Live Activity refreshes should include the session after the registry records streaming runtime."
            )
        }
    }

    @Test
    func connectionManagerRefreshesLiveActivityWithRegistryRuntimeStates() async {
        await withCleanConnectionManager { manager in
            let server = makeServer()
            let staleDomainSession = ConnectionSession(
                serverId: server.id,
                title: "Stale Domain Connecting",
                connectionState: .connecting
            )
            var refreshedStates: [[TerminalEntityConnectionState]] = []
            manager.liveActivityRefresh = { snapshots in
                refreshedStates.append(snapshots.map(\.state))
            }

            // Given a restored session whose domain snapshot still says
            // connecting, while the registry has no live runtime yet.
            manager.sessions = [staleDomainSession]

            #expect(
                refreshedStates.last == [],
                "Live Activity refreshes must ignore opening states that exist only in the domain snapshot."
            )

            // When the application-layer registry records the terminal runtime
            // as streaming and the domain snapshot later remains stale.
            manager.updateSessionState(staleDomainSession.id, to: .connected)
            manager.sessions[0].connectionState = .connecting

            // Then the Live Activity refresh uses the registry runtime state,
            // not the stale ConnectionSession.connectionState snapshot.
            #expect(
                refreshedStates.last == [.streaming],
                "Live Activity status should be derived from TerminalConnectionRegistry runtime state."
            )
        }
    }

    @Test
    func tabManagerActiveServersComeFromRegistryNotDomainPaneState() async {
        await withCleanTabManager { manager in
            let server = makeServer()
            let tabId = UUID()
            let paneId = UUID()
            var paneState = TerminalPaneState(paneId: paneId, tabId: tabId, serverId: server.id)
            paneState.connectionState = .connected

            manager.paneStates[paneId] = paneState

            #expect(
                manager.activeServerIds.isEmpty,
                "A stale domain pane state must not make a server active without a streaming runtime in the registry."
            )
        }
    }

    @Test
    func tabManagerReportsLiveRuntimeFromRegistryNotPaneStateSnapshot() async {
        await withCleanTabManager { manager in
            let server = makeServer()
            let tabId = UUID()
            let paneId = UUID()
            var stalePane = TerminalPaneState(paneId: paneId, tabId: tabId, serverId: server.id)
            stalePane.connectionState = .disconnected
            manager.paneStates[paneId] = stalePane

            // Given a pane whose domain snapshot still says disconnected.
            #expect(
                !manager.hasLiveRuntime(forPaneId: paneId),
                "A pane without registry opening/streaming state should not be considered live."
            )

            // When the application-layer registry records the runtime as opening.
            manager.updatePaneState(paneId, connectionState: .connecting)

            // Then liveness comes from the registry, not the stale pane snapshot
            // value used for display.
            #expect(
                manager.hasLiveRuntime(forPaneId: paneId),
                "Pane runtime liveness should be true when the registry is opening or streaming."
            )
        }
    }

    @Test
    func connectionManagerOtherActiveSessionsComeFromRegistryNotDomainState() async {
        await withCleanConnectionManager { manager in
            let server = makeServer()
            let staleSession = ConnectionSession(
                serverId: server.id,
                title: "Stale",
                connectionState: .connected
            )
            let closingSession = ConnectionSession(
                serverId: server.id,
                title: "Closing",
                connectionState: .disconnected
            )

            manager.sessions = [staleSession, closingSession]

            #expect(
                !manager.hasOtherActiveSessions(for: server.id, excluding: closingSession.id),
                "A stale domain session state must not count as another active session without registry state."
            )

            manager.updateSessionState(staleSession.id, to: .connected)

            #expect(
                manager.hasOtherActiveSessions(for: server.id, excluding: closingSession.id),
                "A registry streaming state should count as another active session."
            )
        }
    }

    @Test
    func tabManagerOtherActivePanesComeFromRegistryNotDomainState() async {
        await withCleanTabManager { manager in
            let server = makeServer()
            let tabId = UUID()
            let stalePaneId = UUID()
            let closingPaneId = UUID()
            var stalePane = TerminalPaneState(paneId: stalePaneId, tabId: tabId, serverId: server.id)
            stalePane.connectionState = .connected
            let closingPane = TerminalPaneState(paneId: closingPaneId, tabId: tabId, serverId: server.id)

            manager.paneStates = [
                stalePaneId: stalePane,
                closingPaneId: closingPane
            ]

            #expect(
                !manager.hasOtherActivePanes(for: server.id, excluding: closingPaneId),
                "A stale domain pane state must not count as another active pane without registry state."
            )

            manager.updatePaneState(stalePaneId, connectionState: .connected)

            #expect(
                manager.hasOtherActivePanes(for: server.id, excluding: closingPaneId),
                "A registry streaming state should count as another active pane."
            )
        }
    }

    @Test
    func connectionManagerUnregisterWithoutShellClearsPendingStart() async {
        await withCleanConnectionManager { manager in
            let session = ConnectionSession(
                serverId: UUID(),
                title: "Session B",
                connectionState: .connecting
            )
            manager.sessions = [session]

            let firstClient = SSHClient()
            #expect(manager.tryBeginShellStart(for: session.id, client: firstClient))

            await manager.unregisterSSHClient(for: session.id)
            #expect(!manager.isShellStartInFlight(for: session.id))
            #expect(manager.shellId(for: session.id) == nil)

            let nextClient = SSHClient()
            #expect(manager.tryBeginShellStart(for: session.id, client: nextClient))
            manager.finishShellStart(for: session.id, client: nextClient)
        }
    }

    @Test
    func connectionManagerCloseSessionAndWaitWaitsForShellTeardownAndUnregister() async {
        await withCleanConnectionManager { manager in
            let serverId = UUID()
            let session = ConnectionSession(
                serverId: serverId,
                title: "Awaited Close",
                connectionState: .connected
            )
            manager.sessions = [session]
            manager.selectedSessionId = session.id
            manager.updateSessionState(session.id, to: .connected)

            manager.registerSSHClient(
                SSHClient(),
                shellId: UUID(),
                for: session.id,
                serverId: serverId,
                skipTmuxLifecycle: true
            )

            var teardownFinished = false
            manager.registerShellCancelHandler({ _ in
                try? await Task.sleep(for: .milliseconds(50))
                teardownFinished = true
            }, for: session.id)

            await manager.closeSessionAndWait(session, notingSessionEnd: false)

            #expect(teardownFinished)
            #expect(manager.shellId(for: session.id) == nil)
            #expect(!manager.sessions.contains { $0.id == session.id })
        }
    }

    @Test
    func tabManagerRejectsStaleRegistrationFromDifferentClient() async {
        await withCleanTabManager { manager in
            let serverId = UUID()
            let tabId = UUID()
            let paneId = UUID()
            manager.paneStates[paneId] = TerminalPaneState(
                paneId: paneId,
                tabId: tabId,
                serverId: serverId
            )

            let activeClient = SSHClient()
            let staleClient = SSHClient()

            #expect(manager.tryBeginShellStart(for: paneId, client: activeClient))

            manager.registerSSHClient(
                staleClient,
                shellId: UUID(),
                for: paneId,
                serverId: serverId,
                skipTmuxLifecycle: true
            )

            #expect(manager.shellId(for: paneId) == nil)
            #expect(manager.isShellStartInFlight(for: paneId))

            manager.finishShellStart(for: paneId, client: staleClient)
            #expect(manager.isShellStartInFlight(for: paneId))

            manager.finishShellStart(for: paneId, client: activeClient)
            #expect(!manager.isShellStartInFlight(for: paneId))
        }
    }

    @Test
    func tabManagerUnregisterWithoutShellClearsPendingStart() async {
        await withCleanTabManager { manager in
            let serverId = UUID()
            let paneId = UUID()
            manager.paneStates[paneId] = TerminalPaneState(
                paneId: paneId,
                tabId: UUID(),
                serverId: serverId
            )

            let firstClient = SSHClient()
            #expect(manager.tryBeginShellStart(for: paneId, client: firstClient))

            await manager.unregisterSSHClient(for: paneId)
            #expect(!manager.isShellStartInFlight(for: paneId))
            #expect(manager.shellId(for: paneId) == nil)

            let nextClient = SSHClient()
            #expect(manager.tryBeginShellStart(for: paneId, client: nextClient))
            manager.finishShellStart(for: paneId, client: nextClient)
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
    func tabManagerHandlePaneExitMarksDisconnectedAndWaitsForUnregister() async {
        await withCleanTabManager { manager in
            let serverId = UUID()
            let paneId = UUID()
            manager.paneStates[paneId] = TerminalPaneState(
                paneId: paneId,
                tabId: UUID(),
                serverId: serverId
            )

            let client = SSHClient()
            #expect(manager.tryBeginShellStart(for: paneId, client: client))

            await manager.handlePaneExit(for: paneId)

            #expect(manager.paneStates[paneId]?.connectionState == .disconnected)
            #expect(!manager.isShellStartInFlight(for: paneId))
            #expect(!manager.hasLiveRuntime(forPaneId: paneId))
        }
    }

    @Test
    func tabManagerCloseTabAndWaitWaitsForPaneUnregister() async {
        await withCleanTabManager { manager in
            let serverId = UUID()
            let tab = TerminalTab(serverId: serverId, title: "Awaited Tab")
            manager.tabsByServer[serverId] = [tab]
            manager.selectedTabByServer[serverId] = tab.id
            manager.paneStates[tab.rootPaneId] = TerminalPaneState(
                paneId: tab.rootPaneId,
                tabId: tab.id,
                serverId: serverId
            )

            manager.registerSSHClient(
                SSHClient(),
                shellId: UUID(),
                for: tab.rootPaneId,
                serverId: serverId,
                skipTmuxLifecycle: true
            )

            await manager.closeTabAndWait(tab)

            #expect(manager.remoteConnectionLease(for: tab.rootPaneId) == nil)
            #expect(manager.shellId(for: tab.rootPaneId) == nil)
            #expect(manager.tabs(for: serverId).isEmpty)
            #expect(manager.paneStates[tab.rootPaneId] == nil)
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
    func tabManagerPaneInputResizeAndCloseUseManagerOwnedRuntime() async {
        await withCleanTabManager { manager in
            // Given a split-pane tab and a fake runtime client owned by the
            // application manager, not by the SwiftUI pane coordinator.
            let serverId = UUID()
            let tab = TerminalTab(serverId: serverId, title: "Runtime Pane")
            let fake = RecordingPaneRuntimeClient()
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
    func connectionManagerTryBeginShellStartFailsWhenSessionIsMissing() async {
        await withCleanConnectionManager { manager in
            let missingSessionId = UUID()
            #expect(!manager.tryBeginShellStart(for: missingSessionId, client: SSHClient()))
            #expect(!manager.isShellStartInFlight(for: missingSessionId))
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
    func tabManagerTryBeginShellStartFailsWhenPaneIsMissing() async {
        await withCleanTabManager { manager in
            let missingPaneId = UUID()
            #expect(!manager.tryBeginShellStart(for: missingPaneId, client: SSHClient()))
            #expect(!manager.isShellStartInFlight(for: missingPaneId))
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
    func connectionManagerSharedStatsLeaseSkipsMoshTransport() async {
        await withCleanConnectionManager { manager in
            let server = makeServer(connectionMode: .mosh)
            let session = ConnectionSession(
                serverId: server.id,
                title: "Mosh Session",
                connectionState: .connected
            )
            manager.sessions = [session]
            manager.selectedSessionId = session.id
            manager.selectedSessionByServer[server.id] = session.id

            let client = SSHClient()
            manager.registerSSHClient(
                client,
                shellId: UUID(),
                for: session.id,
                serverId: server.id,
                transport: .mosh,
                skipTmuxLifecycle: true
            )

            #expect(manager.remoteConnectionLease(forSessionId: session.id) != nil)
            #expect(manager.sharedStatsLease(for: server.id) == nil)
        }
    }

    @Test
    func connectionManagerSharedStatsLeaseUsesRegistryActiveSSHWhenSelectionIsStaleMosh() async {
        await withCleanConnectionManager { manager in
            let server = makeServer(connectionMode: .standard)
            let staleSelected = ConnectionSession(
                serverId: server.id,
                title: "Stale Mosh",
                connectionState: .disconnected,
                activeTransport: .mosh
            )
            let activeSession = ConnectionSession(
                serverId: server.id,
                title: "Active SSH",
                connectionState: .disconnected,
                activeTransport: .ssh
            )
            manager.sessions = [staleSelected, activeSession]
            manager.selectedSessionId = staleSelected.id
            manager.selectedSessionByServer[server.id] = staleSelected.id

            let staleClient = SSHClient()
            manager.registerSSHClient(
                staleClient,
                shellId: UUID(),
                for: staleSelected.id,
                serverId: server.id,
                transport: .mosh,
                skipTmuxLifecycle: true
            )

            let activeClient = SSHClient()
            manager.registerSSHClient(
                activeClient,
                shellId: UUID(),
                for: activeSession.id,
                serverId: server.id,
                transport: .ssh,
                skipTmuxLifecycle: true
            )
            manager.updateSessionState(activeSession.id, to: .connected)

            #expect(
                manager.sharedStatsLease(for: server.id).map { ObjectIdentifier($0.client) } == ObjectIdentifier(activeClient),
                "Stats should use the registry-active SSH session lease instead of a stale selected Mosh session."
            )
        }
    }

    @Test
    func connectionManagerSharedStatsLeaseUsesPendingSSHWhenDomainMoshSnapshotIsStale() async {
        await withCleanConnectionManager { manager in
            let server = makeServer(connectionMode: .standard)
            let staleMoshSession = ConnectionSession(
                serverId: server.id,
                title: "Stale Domain Mosh",
                connectionState: .connected,
                activeTransport: .mosh
            )
            let pendingSSHSession = ConnectionSession(
                serverId: server.id,
                title: "Pending SSH",
                connectionState: .disconnected,
                activeTransport: .ssh
            )
            manager.sessions = [staleMoshSession, pendingSSHSession]

            let pendingClient = SSHClient()
            #expect(manager.tryBeginShellStart(for: pendingSSHSession.id, client: pendingClient))

            #expect(
                manager.sharedStatsLease(for: server.id).map { ObjectIdentifier($0.client) } == ObjectIdentifier(pendingClient),
                "A stale domain Mosh snapshot must not block a pending SSH stats lease."
            )
        }
    }

    @Test
    func connectionManagerRecordsSuccessfulConnectionTransportFromShellRegistry() async {
        await withCleanConnectionManager { manager in
            let server = makeServer(connectionMode: .standard)
            let session = ConnectionSession(
                serverId: server.id,
                title: "Stale Transport",
                connectionState: .disconnected,
                activeTransport: .mosh
            )
            var recorded: [(id: UUID, transport: String)] = []
            manager.successfulConnectionRecorder = { id, transport in
                recorded.append((id: id, transport: transport))
            }
            manager.sessions = [session]

            manager.registerSSHClient(
                SSHClient(),
                shellId: UUID(),
                for: session.id,
                serverId: server.id,
                transport: .ssh,
                skipTmuxLifecycle: true
            )

            // When the runtime reaches connected while the domain transport
            // snapshot is stale.
            manager.updateSessionState(session.id, to: .connected)

            // Then successful-connection recording uses the registered shell
            // transport rather than ConnectionSession.activeTransport.
            #expect(
                recorded.map(\.id) == [session.id],
                "The session should be recorded exactly once when it reaches connected."
            )
            #expect(
                recorded.map(\.transport) == [ShellTransport.ssh.rawValue],
                "Successful connection transport should come from the live shell registry."
            )
        }
    }

    @Test
    func connectionManagerDefaultsSuccessfulConnectionTransportWhenRuntimeIsUnregistered() async {
        await withCleanConnectionManager { manager in
            let server = makeServer(connectionMode: .standard)
            let session = ConnectionSession(
                serverId: server.id,
                title: "Unregistered Runtime",
                connectionState: .disconnected,
                activeTransport: .mosh
            )
            var recorded: [(id: UUID, transport: String)] = []
            manager.successfulConnectionRecorder = { id, transport in
                recorded.append((id: id, transport: transport))
            }
            manager.sessions = [session]

            // When a restored or partially torn-down session reaches connected
            // without a live shell registry entry.
            manager.updateSessionState(session.id, to: .connected)

            // Then the recorder uses the explicit default transport rather than
            // trusting stale ConnectionSession.activeTransport.
            #expect(
                recorded.map(\.id) == [session.id],
                "The session should still be recorded when it reaches connected."
            )
            #expect(
                recorded.map(\.transport) == [ShellTransport.ssh.rawValue],
                "Unregistered runtime should record the safe default SSH transport."
            )
        }
    }

    @Test
    func tabManagerSharedStatsLeaseSkipsMoshTransport() async {
        await withCleanTabManager { manager in
            let server = makeServer(connectionMode: .mosh)
            let tab = TerminalTab(serverId: server.id, title: server.name)
            manager.tabsByServer[server.id] = [tab]
            manager.selectedTabByServer[server.id] = tab.id
            manager.paneStates[tab.rootPaneId] = TerminalPaneState(
                paneId: tab.rootPaneId,
                tabId: tab.id,
                serverId: server.id
            )

            let client = SSHClient()
            manager.registerSSHClient(
                client,
                shellId: UUID(),
                for: tab.rootPaneId,
                serverId: server.id,
                transport: .mosh,
                skipTmuxLifecycle: true
            )

            #expect(manager.remoteConnectionLease(for: tab.rootPaneId) != nil)
            #expect(manager.sharedStatsLease(for: server.id) == nil)
        }
    }

    @Test
    func tabManagerSharedStatsLeaseUsesRegistryActiveSSHWhenSelectionIsStaleMosh() async {
        await withCleanTabManager { manager in
            let server = makeServer(connectionMode: .standard)
            let stalePaneId = UUID()
            let activePaneId = UUID()
            let tab = TerminalTab(
                serverId: server.id,
                title: server.name,
                rootPaneId: stalePaneId,
                focusedPaneId: stalePaneId
            )
            manager.tabsByServer[server.id] = [tab]
            manager.selectedTabByServer[server.id] = tab.id

            var stalePane = TerminalPaneState(paneId: stalePaneId, tabId: tab.id, serverId: server.id)
            stalePane.connectionState = .disconnected
            stalePane.activeTransport = .mosh
            manager.paneStates[stalePaneId] = stalePane

            var activePane = TerminalPaneState(paneId: activePaneId, tabId: tab.id, serverId: server.id)
            activePane.connectionState = .disconnected
            activePane.activeTransport = .ssh
            manager.paneStates[activePaneId] = activePane

            let staleClient = SSHClient()
            manager.registerSSHClient(
                staleClient,
                shellId: UUID(),
                for: stalePaneId,
                serverId: server.id,
                transport: .mosh,
                skipTmuxLifecycle: true
            )

            let activeClient = SSHClient()
            manager.registerSSHClient(
                activeClient,
                shellId: UUID(),
                for: activePaneId,
                serverId: server.id,
                transport: .ssh,
                skipTmuxLifecycle: true
            )
            manager.updatePaneState(activePaneId, connectionState: .connected)

            #expect(
                manager.sharedStatsLease(for: server.id).map { ObjectIdentifier($0.client) } == ObjectIdentifier(activeClient),
                "Stats should use the registry-active SSH pane lease instead of a stale selected Mosh pane."
            )
        }
    }

    @Test
    func tabManagerSharedStatsLeaseUsesPendingSSHWhenDomainMoshSnapshotIsStale() async {
        await withCleanTabManager { manager in
            let server = makeServer(connectionMode: .standard)
            let stalePaneId = UUID()
            let pendingPaneId = UUID()
            let tab = TerminalTab(
                serverId: server.id,
                title: server.name,
                rootPaneId: stalePaneId,
                focusedPaneId: stalePaneId
            )
            manager.tabsByServer[server.id] = [tab]

            var stalePane = TerminalPaneState(paneId: stalePaneId, tabId: tab.id, serverId: server.id)
            stalePane.connectionState = .connected
            stalePane.activeTransport = .mosh
            manager.paneStates[stalePaneId] = stalePane

            var pendingPane = TerminalPaneState(paneId: pendingPaneId, tabId: tab.id, serverId: server.id)
            pendingPane.connectionState = .disconnected
            pendingPane.activeTransport = .ssh
            manager.paneStates[pendingPaneId] = pendingPane

            let pendingClient = SSHClient()
            #expect(manager.tryBeginShellStart(for: pendingPaneId, client: pendingClient))

            #expect(
                manager.sharedStatsLease(for: server.id).map { ObjectIdentifier($0.client) } == ObjectIdentifier(pendingClient),
                "A stale domain Mosh pane snapshot must not block a pending SSH stats lease."
            )
        }
    }

    @Test
    func tabManagerRecordsSuccessfulConnectionTransportFromShellRegistry() async {
        await withCleanTabManager { manager in
            let server = makeServer(connectionMode: .standard)
            let tab = TerminalTab(serverId: server.id, title: server.name)
            var stalePane = TerminalPaneState(
                paneId: tab.rootPaneId,
                tabId: tab.id,
                serverId: server.id
            )
            stalePane.connectionState = .disconnected
            stalePane.activeTransport = .mosh
            var recorded: [(id: UUID, transport: String)] = []
            manager.successfulConnectionRecorder = { id, transport in
                recorded.append((id: id, transport: transport))
            }
            manager.tabsByServer[server.id] = [tab]
            manager.paneStates[tab.rootPaneId] = stalePane

            manager.registerSSHClient(
                SSHClient(),
                shellId: UUID(),
                for: tab.rootPaneId,
                serverId: server.id,
                transport: .ssh,
                skipTmuxLifecycle: true
            )

            // When the pane runtime reaches connected while the pane transport
            // snapshot is stale.
            manager.updatePaneState(tab.rootPaneId, connectionState: .connected)

            // Then successful-connection recording uses the registered shell
            // transport rather than TerminalPaneState.activeTransport.
            #expect(
                recorded.map(\.id) == [tab.rootPaneId],
                "The pane should be recorded exactly once when it reaches connected."
            )
            #expect(
                recorded.map(\.transport) == [ShellTransport.ssh.rawValue],
                "Successful pane transport should come from the live shell registry."
            )
        }
    }

    @Test
    func tabManagerDefaultsSuccessfulConnectionTransportWhenRuntimeIsUnregistered() async {
        await withCleanTabManager { manager in
            let server = makeServer(connectionMode: .standard)
            let tab = TerminalTab(serverId: server.id, title: server.name)
            var stalePane = TerminalPaneState(
                paneId: tab.rootPaneId,
                tabId: tab.id,
                serverId: server.id
            )
            stalePane.connectionState = .disconnected
            stalePane.activeTransport = .mosh
            var recorded: [(id: UUID, transport: String)] = []
            manager.successfulConnectionRecorder = { id, transport in
                recorded.append((id: id, transport: transport))
            }
            manager.tabsByServer[server.id] = [tab]
            manager.paneStates[tab.rootPaneId] = stalePane

            // When a pane reaches connected without a live shell registry entry.
            manager.updatePaneState(tab.rootPaneId, connectionState: .connected)

            // Then successful-connection recording does not reuse the stale
            // TerminalPaneState.activeTransport snapshot.
            #expect(
                recorded.map(\.id) == [tab.rootPaneId],
                "The pane should still be recorded when it reaches connected."
            )
            #expect(
                recorded.map(\.transport) == [ShellTransport.ssh.rawValue],
                "Unregistered pane runtime should record the safe default SSH transport."
            )
        }
    }

    @Test
    func tabManagerLivePaneIndicatorComesFromRegistryNotPaneStateSnapshots() async {
        await withCleanTabManager { manager in
            let server = makeServer(connectionMode: .standard)
            let tab = TerminalTab(serverId: server.id, title: server.name)
            manager.tabsByServer[server.id] = [tab]
            manager.selectedTabByServer[server.id] = tab.id

            var stalePaneState = TerminalPaneState(
                paneId: tab.rootPaneId,
                tabId: tab.id,
                serverId: server.id
            )
            stalePaneState.connectionState = .connected
            manager.paneStates[tab.rootPaneId] = stalePaneState

            #expect(
                !manager.hasLivePanes,
                "A stale pane snapshot must not make the tab manager report live pane runtime."
            )

            manager.registerSSHClient(
                SSHClient(),
                shellId: UUID(),
                for: tab.rootPaneId,
                serverId: server.id,
                transport: .ssh,
                skipTmuxLifecycle: true
            )
            manager.updatePaneState(tab.rootPaneId, connectionState: .connected)

            #expect(
                manager.hasLivePanes,
                "Live pane state should turn true only after the registry records streaming runtime."
            )
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

private struct TestConnectionSessionsSnapshot: Codable {
    struct SessionSnapshot: Codable {
        let id: UUID
        let serverId: UUID
        let title: String
        let createdAt: Date
        let lastActivity: Date
        let autoReconnect: Bool
        let parentSessionId: UUID?
        let workingDirectory: String?
        let presentationOverrides: TerminalPresentationOverrides?
    }

    struct ServerSnapshot: Codable {
        let serverId: UUID
        let selectedSessionId: UUID?
        let selectedView: String?
    }

    let sessions: [SessionSnapshot]
    let selectedSessionId: UUID?
    let serverSelections: [ServerSnapshot]
}

private struct TestTerminalTabsSnapshot: Codable {
    struct ServerSnapshot: Codable {
        let serverId: UUID
        let tabs: [TabSnapshot]
        let selectedTabId: UUID?
        let selectedView: String?
    }

    struct TabSnapshot: Codable {
        let id: UUID
        let serverId: UUID
        let title: String
        let createdAt: Date
        let layout: TerminalSplitNode?
        let focusedPaneId: UUID
        let rootPaneId: UUID
        let panePresentationOverrides: [UUID: TerminalPresentationOverrides]?
    }

    let servers: [ServerSnapshot]
}

private actor RecordingPaneRuntimeClient: TerminalConnectionClient {
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
