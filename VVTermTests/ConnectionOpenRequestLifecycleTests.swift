import Foundation
import Testing
@testable import VVTerm

// Test Context:
// These integration tests protect user-initiated terminal open request
// lifecycle ordering. They use real ConnectionSessionManager and
// TerminalTabManager instances with injected blocking gates, so failures
// usually mean open/reconnect intent coalescing, security unlock ordering,
// callback delivery, or close-cancellation behavior moved out of the
// application manager boundary. Update only when that open request contract
// intentionally changes.

@Suite(.serialized)
@MainActor
struct ConnectionOpenRequestLifecycleTests {
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
    func tabOpenRequestTracksCompletionAndRunsSuccessCallback() async {
        await withCleanTabManager { manager in
            let server = makeServer()
            var openedTabId: UUID?

            // Given SwiftUI sends terminal tab open intent synchronously.
            let requestID = manager.requestTabOpen(for: server) { tab in
                openedTabId = tab.id
            }

            // Then the application manager owns the open task and exposes an
            // awaitable request boundary for ordering-sensitive callers.
            #expect(
                manager.pendingTabOpenRequestIDs.contains(requestID),
                "A user-initiated tab open must be tracked by TerminalTabManager until completion."
            )

            await manager.waitForTabOpenRequest(requestID)

            #expect(
                openedTabId != nil,
                "The tab open request should report the created tab through the success callback."
            )
            #expect(
                !manager.pendingTabOpenRequestIDs.contains(requestID),
                "TerminalTabManager should remove the open request after the task finishes."
            )
            #expect(
                manager.lastTabOpenFailure == nil,
                "Successful tab open requests should not leave stale failure state."
            )
        }
    }

    @Test
    func serverTerminalOpenRequestAuthenticatesBeforeSelectingExistingTab() async {
        await withCleanTabManager { manager in
            let server = makeServer()
            let existingTab = TerminalTab(serverId: server.id, title: server.name)
            manager.tabsByServer[server.id] = [existingTab]
            var unlockCalls: [UUID] = []
            var openedTabId: UUID?

            manager.setServerUnlockerForTesting { unlockedServer in
                unlockCalls.append(unlockedServer.id)
                return unlockedServer.id == server.id
            }

            // Given SwiftUI sends terminal open intent for a server that
            // already has a tab.
            let requestID = manager.requestServerTerminalOpen(
                for: server,
                selectTerminalViewOnSuccess: true
            ) { tab in
                openedTabId = tab.id
            }

            await manager.waitForTabOpenRequest(requestID)

            // Then TerminalTabManager still runs the unlock gate before it
            // focuses the existing tab, matching the pre-refactor security
            // behavior while keeping the lifecycle task manager-owned.
            #expect(
                unlockCalls == [server.id],
                "Existing terminal tabs must not bypass the server unlock gate."
            )
            #expect(
                openedTabId == existingTab.id,
                "The open intent should report the existing tab after unlock succeeds."
            )
            #expect(
                manager.selectedViewByServer[server.id] == ViewTabConfigurationManager.shared.effectiveDefaultTab(),
                "Selecting an existing terminal tab should happen only after the manager-owned unlock path succeeds."
            )
        }
    }

    @Test
    func connectionOpenRequestWaitsForPendingDisconnectAndRunsSuccessCallback() async {
        await withCleanConnectionManager { manager in
            let server = makeServer()
            let disconnectGate = OpenRequestTaskGate()
            let disconnectTask = Task {
                await disconnectGate.waitForRelease()
            }
            manager.setServerDisconnectTaskForTesting(server.id, task: disconnectTask)
            var openedSessionId: UUID?

            await withServerList([server]) {
                // Given an iOS server-list tap sends open intent while a same
                // server disconnect cleanup is still running.
                let requestID = manager.requestConnectionOpen(to: server) { session in
                    openedSessionId = session.id
                }

                // Then ConnectionSessionManager owns the pending open and keeps
                // it awaitable while the existing cleanup finishes.
                #expect(
                    manager.pendingConnectionOpenRequestIDs.contains(requestID),
                    "A user-initiated connection open must stay tracked while waiting for disconnect cleanup."
                )

                await disconnectGate.release()
                await manager.waitForConnectionOpenRequest(requestID)

                #expect(
                    openedSessionId != nil,
                    "The connection open request should report the created session through the success callback."
                )
                #expect(
                    !manager.pendingConnectionOpenRequestIDs.contains(requestID),
                    "ConnectionSessionManager should remove the open request after the task finishes."
                )
                #expect(
                    manager.lastConnectionOpenFailure == nil,
                    "Successful connection open requests should not leave stale failure state."
                )
            }
        }
    }

    @Test
    func activeConnectionOpenRequestTracksReconnectUntilCompletion() async {
        await withCleanConnectionManager { manager in
            let server = makeServer()
            let session = ConnectionSession(
                serverId: server.id,
                title: server.name,
                connectionState: .failed("Disconnected")
            )
            manager.sessions = [session]
            let reconnectGate = OpenRequestTaskGate()
            var reconnectCalls: [UUID] = []
            var didOpen = false

            manager.setActiveConnectionOpenReconnectOperationForTesting { requestSession in
                reconnectCalls.append(requestSession.id)
                await reconnectGate.waitForRelease()
                return true
            }

            // Given the iOS Active Connections row sends open intent for a
            // saved session whose runtime must be checked/reconnected first.
            let requestID = manager.requestActiveConnectionOpen(
                session: session,
                preferredViewId: "terminal"
            ) {
                didOpen = true
            }

            // Then ConnectionSessionManager owns the pending reconnect/select
            // work until the manager-owned request exits.
            #expect(
                manager.pendingActiveConnectionOpenRequestIDs.contains(requestID),
                "Active Connection open should stay tracked while reconnect work is in flight."
            )
            #expect(!didOpen)

            await reconnectGate.release()
            await manager.waitForActiveConnectionOpenRequest(requestID)

            #expect(
                reconnectCalls == [session.id],
                "Active Connection open should run reconnect/runtime liveness work once for the selected session."
            )
            #expect(manager.selectedSessionId == session.id)
            #expect(manager.selectedViewByServer[server.id] == "terminal")
            #expect(didOpen)
            #expect(!manager.pendingActiveConnectionOpenRequestIDs.contains(requestID))
        }
    }

    @Test
    func duplicateActiveConnectionOpenRequestsCoalesceUntilCompletion() async {
        await withCleanConnectionManager { manager in
            let server = makeServer()
            let session = ConnectionSession(
                serverId: server.id,
                title: server.name,
                connectionState: .failed("Disconnected")
            )
            manager.sessions = [session]
            let reconnectGate = OpenRequestTaskGate()
            var reconnectCalls: [UUID] = []
            var callbacks: [String] = []

            manager.setActiveConnectionOpenReconnectOperationForTesting { requestSession in
                reconnectCalls.append(requestSession.id)
                await reconnectGate.waitForRelease()
                return true
            }

            // Given an Active Connection open request is already waiting for
            // reconnect/runtime liveness work to finish.
            let firstID = manager.requestActiveConnectionOpen(
                session: session,
                preferredViewId: "terminal"
            ) {
                callbacks.append("first")
            }
            let secondID = manager.requestActiveConnectionOpen(
                session: session,
                preferredViewId: "terminal"
            ) {
                callbacks.append("second")
            }

            // Then duplicate same-session intent joins the existing request
            // instead of starting duplicate reconnect/select work.
            #expect(firstID == secondID)
            #expect(manager.pendingActiveConnectionOpenRequestIDs == [firstID])

            await reconnectGate.release()
            await manager.waitForActiveConnectionOpenRequest(firstID)

            #expect(reconnectCalls == [session.id])
            #expect(callbacks == ["first", "second"])
            #expect(!manager.pendingActiveConnectionOpenRequestIDs.contains(firstID))
        }
    }

    @Test
    func activeConnectionOpenCancellationDoesNotSelectOrCallback() async {
        await withCleanConnectionManager { manager in
            let server = makeServer()
            let session = ConnectionSession(
                serverId: server.id,
                title: server.name,
                connectionState: .failed("Disconnected")
            )
            manager.sessions = [session]
            let reconnectGate = OpenRequestTaskGate()
            var didOpen = false

            manager.setActiveConnectionOpenReconnectOperationForTesting { _ in
                await reconnectGate.waitForRelease()
                return true
            }

            // Given lifecycle teardown cancels a pending Active Connection open
            // before reconnect/runtime liveness work completes.
            let requestID = manager.requestActiveConnectionOpen(
                session: session,
                preferredViewId: "terminal"
            ) {
                didOpen = true
            }
            manager.cancelActiveConnectionOpenRequestForTesting(requestID)

            await reconnectGate.release()
            await manager.waitForActiveConnectionOpenRequest(requestID)

            // Then cancellation is lifecycle completion: no presentation
            // callback runs and no stale selection/view state is written.
            #expect(!didOpen)
            #expect(manager.selectedSessionId == nil)
            #expect(manager.selectedViewByServer[server.id] == nil)
            #expect(!manager.pendingActiveConnectionOpenRequestIDs.contains(requestID))
        }
    }

    @Test
    func closeSessionCancelsPendingActiveConnectionOpenRequest() async {
        await withCleanConnectionManager { manager in
            let server = makeServer()
            let session = ConnectionSession(
                serverId: server.id,
                title: server.name,
                connectionState: .failed("Disconnected")
            )
            manager.sessions = [session]
            let reconnectGate = OpenRequestTaskGate()
            var didOpen = false

            manager.setActiveConnectionOpenReconnectOperationForTesting { _ in
                await reconnectGate.waitForRelease()
                return true
            }

            // Given an Active Connection open request is pending when the
            // owning session is closed.
            let requestID = manager.requestActiveConnectionOpen(
                session: session,
                preferredViewId: "terminal"
            ) {
                didOpen = true
            }
            #expect(manager.pendingActiveConnectionOpenRequestIDs.contains(requestID))

            await manager.closeSessionAndWait(session)
            let waitProbe = OpenRequestWaitProbe()
            let waitTask = Task {
                await manager.waitForActiveConnectionOpenRequest(requestID)
                await waitProbe.markReturned()
            }
            try? await Task.sleep(for: .milliseconds(20))

            // Then closing the session cancels the visible request immediately.
            #expect(
                !manager.pendingActiveConnectionOpenRequestIDs.contains(requestID),
                "Closing a session should cancel pending Active Connection open intent for that session."
            )
            #expect(
                await !waitProbe.didReturn,
                "Active Connection open wait hook must remain tracked until the blocked reconnect operation exits."
            )

            await reconnectGate.release()
            await waitTask.value
            #expect(await waitProbe.didReturn)

            #expect(!didOpen)
            #expect(manager.selectedSessionId == nil)
            #expect(manager.selectedViewByServer[server.id] == nil)
        }
    }
}

private actor OpenRequestTaskGate {
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var isReleased = false

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
}

private actor OpenRequestWaitProbe {
    private(set) var didReturn = false

    func markReturned() {
        didReturn = true
    }
}
