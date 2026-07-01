import Foundation
import Testing
@testable import Waterm

// Test Context:
// These integration tests protect stats lease selection and successful
// connection transport recording. They use real manager singletons with
// registered in-memory SSH clients, so failures usually mean runtime registry
// state stopped being the source of truth over stale domain transport
// snapshots. Update only when the intended stats/transport ownership changes.

@Suite(.serialized)
@MainActor
struct ConnectionStatsLeaseTransportTests {
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

            // Given the selected session is live through Mosh transport.
            #expect(manager.remoteConnectionLease(forSessionId: session.id) != nil)

            // Then shared stats must not borrow that Mosh transport for SSH stats collection.
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

            // Then stats use the registry-active SSH session lease instead of
            // a stale selected Mosh session.
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

            // Given a new SSH shell start is pending while domain state still
            // claims a connected Mosh snapshot.
            let pendingClient = SSHClient()
            #expect(manager.tryBeginShellStart(for: pendingSSHSession.id, client: pendingClient))

            // Then the pending SSH registry client remains available for stats.
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

            // Given the selected pane is live through Mosh transport.
            #expect(manager.remoteConnectionLease(for: tab.rootPaneId) != nil)

            // Then shared stats must not borrow that Mosh transport for SSH stats collection.
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

            // Then stats use the registry-active SSH pane lease instead of a
            // stale selected Mosh pane.
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

            // Given a new SSH shell start is pending while pane state still
            // claims a connected Mosh snapshot.
            let pendingClient = SSHClient()
            #expect(manager.tryBeginShellStart(for: pendingPaneId, client: pendingClient))

            // Then the pending SSH registry client remains available for stats.
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
}
