import Foundation
import Testing
@testable import Waterm

// Test Context:
// These integration tests protect runtime registry ownership for terminal
// session and pane liveness. They use real app managers with fake terminal
// clients and restored snapshots, so failures usually mean active/open state,
// Live Activity projection, or stale UI/domain snapshot handling moved across
// the application boundary. Update only when the registry liveness contract
// intentionally changes.

@Suite(.serialized)
@MainActor
struct ConnectionRuntimeRegistryLifecycleTests {
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
    func connectionManagerRestoredSessionsAreOpenButNotActiveUntilRuntimeStreams() async throws {
        try await withCleanConnectionManager { manager in
            let server = makeServer()
            let sessionId = UUID()
            let snapshot = RegistryConnectionSessionsSnapshot(
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

            let client = RegistryRecordingPaneRuntimeClient()
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
            let snapshot = RegistryTerminalTabsSnapshot(
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

            let client = RegistryRecordingPaneRuntimeClient()
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
    func tabManagerManualReconnectIntentUsesManagerRuntimeState() async {
        await withCleanTabManager { manager in
            let server = makeServer()
            let tabId = UUID()
            let paneId = UUID()
            var paneState = TerminalPaneState(paneId: paneId, tabId: tabId, serverId: server.id)
            paneState.connectionState = .disconnected
            manager.paneStates[paneId] = paneState

            // Given split SwiftUI sends only retry intent and the application
            // layer owns the runtime liveness decision.
            #expect(
                manager.shouldManuallyReconnectPane(paneId, reconnectInFlight: false),
                "Disconnected panes without live runtime should accept manual reconnect intent."
            )

            // When the registry records an opening runtime while the display
            // snapshot later appears disconnected.
            manager.updatePaneState(paneId, connectionState: .connecting)
            manager.paneStates[paneId]?.connectionState = .disconnected

            // Then the manager suppresses the duplicate retry without SwiftUI
            // reading registry state directly.
            #expect(
                !manager.shouldManuallyReconnectPane(paneId, reconnectInFlight: false),
                "Manual pane reconnect intent should use manager-owned runtime liveness."
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
}

private struct RegistryConnectionSessionsSnapshot: Codable {
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

private struct RegistryTerminalTabsSnapshot: Codable {
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

private actor RegistryRecordingPaneRuntimeClient: TerminalConnectionClient {
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
