import Foundation
import Testing
@testable import VVTerm

// Test Context:
// These integration tests protect shell registration and teardown ownership for
// root sessions and split panes. They use real app-level managers with fake
// SSHClient instances and injected cleanup hooks, so failures usually mean
// stale shell callbacks, missing entity rejection, awaited teardown, or
// same-server cleanup ordering changed. Update only when the shell registration
// lifecycle contract intentionally changes.

@Suite(.serialized)
@MainActor
struct ConnectionShellRegistrationLifecycleTests {
    private func makeServer(
        id: UUID = UUID(),
        workspaceId: UUID = UUID(),
        name: String = "Test",
        connectionMode: SSHConnectionMode = .cloudflare,
        multiplexerOverride: TerminalMultiplexer? = nil
    ) -> Server {
        Server(
            id: id,
            workspaceId: workspaceId,
            name: name,
            host: "ssh.example.com",
            username: "root",
            connectionMode: connectionMode,
            multiplexerOverride: multiplexerOverride
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
    func connectionManagerCloseSessionAndWaitKillsManagedZmxSessionWithServerMultiplexer() async throws {
        try await withCleanConnectionManager { manager in
            let server = makeServer(
                name: "ZMX Host",
                connectionMode: .standard,
                multiplexerOverride: .zmx
            )
            let session = ConnectionSession(
                serverId: server.id,
                title: server.name,
                connectionState: .connected,
                tmuxStatus: .foreground
            )
            let tmuxService = RecordingTerminalTmuxService()
            let managedSessionName = "vvterm_zmx_managed"
            manager.sessions = [session]
            manager.selectedSessionId = session.id
            manager.setServerProviderForTesting { requestedId in
                requestedId == server.id ? server : nil
            }
            manager.setTmuxServiceForTesting(tmuxService)
            manager.tmuxResolver.sessionNames[session.id] = managedSessionName
            manager.tmuxResolver.sessionOwnership[session.id] = .managed
            manager.registerSSHClient(
                SSHClient(),
                shellId: UUID(),
                for: session.id,
                serverId: server.id,
                skipTmuxLifecycle: true
            )

            // When a managed zmx-backed session is closed, closeSessionUI removes
            // it from manager.sessions before SSH teardown runs.
            await manager.closeSessionAndWait(session, notingSessionEnd: false)

            // Then teardown still uses the server's zmx multiplexer instead of
            // falling back to tmux after the session disappears from the UI list.
            let killCall = try #require(await tmuxService.killCalls.first)
            #expect(killCall.sessionName == managedSessionName)
            #expect(
                killCall.preferred == .zmx,
                "Closing a managed zmx session must send the zmx backend to remote cleanup after the session row is removed."
            )
        }
    }

    @Test
    func connectionManagerDisconnectAllAndWaitWaitsForEverySessionTeardown() async {
        await withCleanConnectionManager { manager in
            let serverId = UUID()
            let first = ConnectionSession(
                serverId: serverId,
                title: "Termination A",
                connectionState: .connected
            )
            let second = ConnectionSession(
                serverId: serverId,
                title: "Termination B",
                connectionState: .connected
            )
            manager.sessions = [first, second]
            manager.selectedSessionId = first.id

            for session in [first, second] {
                manager.registerSSHClient(
                    SSHClient(),
                    shellId: UUID(),
                    for: session.id,
                    serverId: serverId,
                    skipTmuxLifecycle: true
                )
            }

            var finishedTeardowns: Set<UUID> = []
            for session in [first, second] {
                manager.registerShellCancelHandler({ _ in
                    try? await Task.sleep(for: .milliseconds(50))
                    finishedTeardowns.insert(session.id)
                }, for: session.id)
            }

            await manager.disconnectAllAndWait()

            #expect(
                finishedTeardowns == [first.id, second.id],
                "App termination cleanup must wait for every session shell teardown before reporting completion."
            )
            #expect(manager.sessions.isEmpty)
            #expect(manager.shellId(for: first.id) == nil)
            #expect(manager.shellId(for: second.id) == nil)
        }
    }

    @Test
    func connectionManagerDisconnectAllAndWaitPersistsClearedSnapshotBeforeReturning() async throws {
        try await withCleanConnectionManager { manager in
            let session = ConnectionSession(
                serverId: UUID(),
                title: "Restored Session",
                connectionState: .connected
            )
            manager.sessions = [session]
            manager.selectedSessionId = session.id
            try manager.snapshotStore.save(
                ConnectionSessionsSnapshot(
                    sessions: [.init(from: session)],
                    selectedSessionId: session.id,
                    serverSelections: [
                        .init(serverId: session.serverId, selectedSessionId: session.id, selectedView: "terminal")
                    ]
                )
            )

            // When app-termination teardown closes every session and returns.
            await manager.disconnectAllAndWait()

            // Then relaunch restore must not see the stale pre-teardown session.
            let snapshot = try #require(try manager.snapshotStore.load())
            #expect(
                snapshot.sessions.isEmpty,
                "disconnectAllAndWait must flush the cleared session snapshot before app termination can continue."
            )
            #expect(snapshot.selectedSessionId == nil)
            #expect(
                manager.persistTask == nil,
                "disconnectAllAndWait must cancel the debounced session persistence task after flushing."
            )
        }
    }

    @Test
    func connectionManagerLruEvictionTracksShellCleanupBeforeSameServerReopen() async throws {
        try await withCleanConnectionManager { manager in
            let wasPro = StoreManager.shared.isPro
            StoreManager.shared.isPro = true
            defer { StoreManager.shared.isPro = wasPro }

            let server = makeServer(name: "Tencent", connectionMode: .standard)
            let evictedSession = ConnectionSession(
                serverId: server.id,
                title: "Evicted",
                connectionState: .connected
            )
            manager.sessions = [evictedSession]
            manager.selectedSessionId = nil

            manager.registerSSHClient(
                SSHClient(),
                shellId: UUID(),
                for: evictedSession.id,
                serverId: server.id,
                skipTmuxLifecycle: true
            )

            var evictionTeardownFinished = false
            manager.registerShellCancelHandler({ _ in
                try? await Task.sleep(for: .milliseconds(100))
                evictionTeardownFinished = true
            }, for: evictedSession.id)

            manager.registerTerminalForTesting(sessionId: evictedSession.id)
            for index in 0..<20 {
                let cachedSession = ConnectionSession(
                    serverId: UUID(),
                    title: "Cached \(index)",
                    connectionState: .connected
                )
                manager.sessions.append(cachedSession)
                manager.registerTerminalForTesting(sessionId: cachedSession.id)
            }

            _ = try await manager.openConnection(to: server, forceNew: true)

            #expect(
                evictionTeardownFinished,
                "Opening the same server after LRU eviction must wait for the evicted session cleanup task."
            )
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
    func connectionManagerRejectsShellRegistrationWhenSessionIsMissing() async {
        await withCleanConnectionManager { manager in
            // Given a late shell callback for a session that no longer exists.
            let missingSessionId = UUID()

            // When the callback attempts to register without a valid entity.
            let accepted = manager.registerSSHClient(
                SSHClient(),
                shellId: UUID(),
                for: missingSessionId,
                serverId: UUID(),
                skipTmuxLifecycle: true
            )

            // Then no orphan shell registration is retained.
            #expect(!accepted)
            #expect(manager.shellId(for: missingSessionId) == nil)
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
    func tabManagerDisconnectAllAndWaitWaitsForEveryPaneUnregister() async {
        await withCleanTabManager { manager in
            let firstServerId = UUID()
            let secondServerId = UUID()
            let firstTab = TerminalTab(serverId: firstServerId, title: "Termination Pane A")
            let secondTab = TerminalTab(serverId: secondServerId, title: "Termination Pane B")

            manager.tabsByServer[firstServerId] = [firstTab]
            manager.tabsByServer[secondServerId] = [secondTab]
            manager.selectedTabByServer[firstServerId] = firstTab.id
            manager.selectedTabByServer[secondServerId] = secondTab.id
            manager.paneStates[firstTab.rootPaneId] = TerminalPaneState(
                paneId: firstTab.rootPaneId,
                tabId: firstTab.id,
                serverId: firstServerId
            )
            manager.paneStates[secondTab.rootPaneId] = TerminalPaneState(
                paneId: secondTab.rootPaneId,
                tabId: secondTab.id,
                serverId: secondServerId
            )

            manager.registerSSHClient(
                SSHClient(),
                shellId: UUID(),
                for: firstTab.rootPaneId,
                serverId: firstServerId,
                skipTmuxLifecycle: true
            )
            manager.registerSSHClient(
                SSHClient(),
                shellId: UUID(),
                for: secondTab.rootPaneId,
                serverId: secondServerId,
                skipTmuxLifecycle: true
            )

            await manager.disconnectAllAndWait()

            #expect(manager.tabs(for: firstServerId).isEmpty)
            #expect(manager.tabs(for: secondServerId).isEmpty)
            #expect(manager.shellId(for: firstTab.rootPaneId) == nil)
            #expect(manager.shellId(for: secondTab.rootPaneId) == nil)
            #expect(manager.paneStates[firstTab.rootPaneId] == nil)
            #expect(manager.paneStates[secondTab.rootPaneId] == nil)
        }
    }

    @Test
    func tabManagerDisconnectAllAndWaitPersistsClearedSnapshotBeforeReturning() async throws {
        try await withCleanTabManager { manager in
            let serverId = UUID()
            let tab = TerminalTab(serverId: serverId, title: "Restored Tab")
            manager.tabsByServer[serverId] = [tab]
            manager.selectedTabByServer[serverId] = tab.id
            manager.paneStates[tab.rootPaneId] = TerminalPaneState(
                paneId: tab.rootPaneId,
                tabId: tab.id,
                serverId: serverId
            )
            try manager.snapshotStore.save(
                TerminalTabsSnapshot(
                    servers: [
                        .init(
                            serverId: serverId,
                            tabs: [.init(from: tab, paneStates: manager.paneStates)],
                            selectedTabId: tab.id,
                            selectedView: "terminal"
                        )
                    ]
                )
            )

            // When app-termination teardown closes every tab and returns.
            await manager.disconnectAllAndWait()

            // Then relaunch restore must not see the stale pre-teardown tab.
            let snapshot = try #require(try manager.snapshotStore.load())
            #expect(
                snapshot.servers.isEmpty,
                "disconnectAllAndWait must flush the cleared tab snapshot before app termination can continue."
            )
            #expect(
                manager.persistTask == nil,
                "disconnectAllAndWait must cancel the debounced tab persistence task after flushing."
            )
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
    func tabManagerRejectsShellRegistrationWhenPaneIsMissing() async {
        await withCleanTabManager { manager in
            // Given a late shell callback for a pane that no longer exists.
            let missingPaneId = UUID()

            // When the callback attempts to register without a valid entity.
            let accepted = manager.registerSSHClient(
                SSHClient(),
                shellId: UUID(),
                for: missingPaneId,
                serverId: UUID(),
                skipTmuxLifecycle: true
            )

            // Then no orphan shell registration is retained.
            #expect(!accepted)
            #expect(manager.shellId(for: missingPaneId) == nil)
        }
    }
}

private final class RecordingTerminalTmuxService: TerminalTmuxServicing, @unchecked Sendable {
    private let recorder = RecordingTerminalTmuxServiceRecorder()

    var killCalls: [KillCall] {
        get async { await recorder.killCalls }
    }

    func tmuxBackend(
        using client: SSHClient,
        preferred: TerminalMultiplexer
    ) async -> RemoteTmuxBackend? {
        .unixTmux
    }

    func tmuxInstallBackend(
        using executor: any RemoteCommandExecuting,
        preferred: TerminalMultiplexer
    ) async -> RemoteTmuxBackend? {
        .unixTmux
    }

    func isTmuxAvailable(
        using executor: any RemoteCommandExecuting,
        preferred: TerminalMultiplexer
    ) async -> Bool {
        true
    }

    func listSessions(
        using executor: any RemoteCommandExecuting,
        backend: RemoteTmuxBackend
    ) async -> [RemoteTmuxSession] {
        []
    }

    func prepareConfig(
        using executor: any RemoteCommandExecuting,
        terminalType: RemoteTerminalType,
        backend: RemoteTmuxBackend
    ) async {}

    func sendScript(_ script: String, using client: SSHClient, shellId: UUID) async {}

    func killSession(
        named sessionName: String,
        using executor: any RemoteCommandExecuting,
        preferred: TerminalMultiplexer
    ) async {
        await recorder.recordKill(sessionName: sessionName, preferred: preferred)
    }

    func cleanupLegacySessions(using executor: any RemoteCommandExecuting) async {}

    func cleanupDetachedSessions(
        deviceId: String,
        keeping sessionNames: Set<String>,
        using executor: any RemoteCommandExecuting,
        preferred: TerminalMultiplexer
    ) async {}

    func currentPath(sessionName: String, using executor: any RemoteCommandExecuting) async -> String? {
        nil
    }

    func startupAttachCommand(
        sessionName: String,
        workingDirectory: String,
        backend: RemoteTmuxBackend
    ) -> String {
        ""
    }

    func startupAttachExistingCommand(sessionName: String, backend: RemoteTmuxBackend) -> String {
        ""
    }

    func interactiveAttachCommand(
        sessionName: String,
        workingDirectory: String,
        backend: RemoteTmuxBackend
    ) -> String {
        ""
    }

    func interactiveAttachExistingCommand(sessionName: String, backend: RemoteTmuxBackend) -> String {
        ""
    }

    func installAndAttachScript(
        sessionName: String,
        workingDirectory: String,
        terminalType: RemoteTerminalType,
        backend: RemoteTmuxBackend
    ) -> String {
        ""
    }

    struct KillCall: Equatable, Sendable {
        let sessionName: String
        let preferred: TerminalMultiplexer
    }
}

private actor RecordingTerminalTmuxServiceRecorder {
    private(set) var killCalls: [RecordingTerminalTmuxService.KillCall] = []

    func recordKill(sessionName: String, preferred: TerminalMultiplexer) {
        killCalls.append(
            RecordingTerminalTmuxService.KillCall(
                sessionName: sessionName,
                preferred: preferred
            )
        )
    }
}
