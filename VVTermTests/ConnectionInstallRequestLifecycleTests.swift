import Foundation
import Testing
@testable import VVTerm

// Test Context:
// These integration tests protect terminal install and host-retrust request
// lifecycle ordering. They use real manager singletons with injected blocking
// operations, so failures usually mean install/retrust request tracking,
// coalescing, cancellation, or callback ordering changed. Update only when the
// intended application-layer request contract changes.

@Suite(.serialized)
@MainActor
struct ConnectionInstallRequestLifecycleTests {
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
    func connectionManagerTracksTmuxInstallRequestUntilOperationCompletes() async {
        await withCleanConnectionManager { manager in
            let session = ConnectionSession(serverId: UUID(), title: "Session")
            let gate = InstallRequestOperationGate()
            manager.sessions = [session]
            manager.setTmuxInstallOperationForTesting { requestSessionId in
                #expect(
                    requestSessionId == session.id,
                    "The tracked tmux install request should target the requested session."
                )
                await gate.run()
            }

            // Given SwiftUI sends tmux install intent and the application
            // layer owns the blocking install operation.
            let requestID = manager.requestTmuxInstall(for: session.id)

            // When the same session asks again before install completion.
            let duplicateRequestID = manager.requestTmuxInstall(for: session.id)
            await gate.waitForCallCount(1)

            // Then the manager coalesces duplicate intent and keeps the
            // request awaitable until the install operation finishes.
            #expect(duplicateRequestID == requestID)
            #expect(
                manager.pendingTmuxInstallRequestIDs == [requestID],
                "Tmux install must remain pending while the application-layer operation is blocked."
            )
            #expect(await gate.callCount == 1)

            await gate.release()
            await manager.waitForTmuxInstallRequest(requestID)

            #expect(
                manager.pendingTmuxInstallRequestIDs.isEmpty,
                "Tmux install request state should clear only after the tracked operation completes."
            )
        }
    }

    @Test
    func connectionManagerCompletesMoshInstallRequestAfterReconnectOperationFinishes() async {
        await withCleanConnectionManager { manager in
            let session = ConnectionSession(serverId: UUID(), title: "Session")
            let gate = InstallRequestOperationGate()
            manager.sessions = [session]
            manager.setMoshInstallAndReconnectOperationForTesting { requestSession in
                #expect(
                    requestSession.id == session.id,
                    "The tracked mosh install request should target the requested session."
                )
                await gate.run()
            }
            var completedCount = 0
            var failedCount = 0

            // Given SwiftUI sends mosh install intent and the manager owns the
            // install-then-reconnect operation.
            let requestID = manager.requestMoshInstallAndReconnect(
                session: session,
                onCompleted: { completedCount += 1 },
                onFailed: { _ in failedCount += 1 }
            )

            // When the operation is still blocked.
            #expect(
                manager.pendingMoshInstallRequestIDs == [requestID],
                "Mosh install should remain pending until install and reconnect complete."
            )
            #expect(completedCount == 0)
            #expect(failedCount == 0)

            // Then completion is reported only after the manager-owned work
            // has finished.
            await gate.release()
            await manager.waitForMoshInstallRequest(requestID)

            #expect(completedCount == 1)
            #expect(failedCount == 0)
            #expect(manager.pendingMoshInstallRequestIDs.isEmpty)
        }
    }

    @Test
    func connectionManagerMoshInstallDuplicateCallersReceiveCompletion() async {
        await withCleanConnectionManager { manager in
            let session = ConnectionSession(serverId: UUID(), title: "Session")
            let gate = InstallRequestOperationGate()
            manager.sessions = [session]
            manager.setMoshInstallAndReconnectOperationForTesting { _ in
                await gate.run()
            }
            var firstCompletedCount = 0
            var secondCompletedCount = 0

            // Given a mosh install request is already pending for this
            // session, as can happen when SwiftUI recreates a view.
            let firstRequestID = manager.requestMoshInstallAndReconnect(
                session: session,
                onCompleted: { firstCompletedCount += 1 },
                onFailed: { _ in }
            )
            let secondRequestID = manager.requestMoshInstallAndReconnect(
                session: session,
                onCompleted: { secondCompletedCount += 1 },
                onFailed: { _ in }
            )

            // When the shared manager-owned operation completes.
            await gate.release()
            await manager.waitForMoshInstallRequest(firstRequestID)

            // Then duplicate intent should coalesce to the same request while
            // still notifying every caller that registered presentation cleanup.
            #expect(secondRequestID == firstRequestID)
            #expect(firstCompletedCount == 1)
            #expect(secondCompletedCount == 1)
        }
    }

    @Test
    func connectionManagerCloseSessionCancelsPendingInstallRequestsAndFinishesMoshCleanup() async {
        await withCleanConnectionManager { manager in
            let session = ConnectionSession(serverId: UUID(), title: "Session")
            let tmuxGate = InstallRequestOperationGate()
            let moshGate = InstallRequestOperationGate()
            manager.sessions = [session]
            manager.setTmuxInstallOperationForTesting { _ in
                await tmuxGate.run()
            }
            manager.setMoshInstallAndReconnectOperationForTesting { _ in
                await moshGate.run()
            }
            var moshCompletedCount = 0
            var moshFailedCount = 0

            // Given tmux and mosh install requests are pending for a session.
            let tmuxRequestID = manager.requestTmuxInstall(for: session.id)
            let moshRequestID = manager.requestMoshInstallAndReconnect(
                session: session,
                onCompleted: { moshCompletedCount += 1 },
                onFailed: { _ in moshFailedCount += 1 }
            )
            await tmuxGate.waitForCallCount(1)
            await moshGate.waitForCallCount(1)

            // When the owning session closes before install work returns.
            await manager.closeSessionAndWait(session)
            await manager.waitForTmuxInstallRequest(tmuxRequestID)
            await manager.waitForMoshInstallRequest(moshRequestID)

            // Then pending install request state should clear and mosh UI
            // cleanup should run as cancellation completion, not failure.
            #expect(manager.pendingTmuxInstallRequestIDs.isEmpty)
            #expect(manager.pendingMoshInstallRequestIDs.isEmpty)
            #expect(moshCompletedCount == 1)
            #expect(moshFailedCount == 0)
            await tmuxGate.release()
            await moshGate.release()
        }
    }

    @Test
    func connectionManagerCloseSessionCancelsPendingHostRetrustRequest() async {
        await withCleanConnectionManager { manager in
            let server = makeServer()
            let session = ConnectionSession(serverId: server.id, title: server.name)
            let gate = InstallRequestOperationGate()
            manager.sessions = [session]
            manager.setSessionHostRetrustOperationForTesting { _, _ in
                await gate.run()
                return true
            }
            var results: [Bool] = []

            // Given a host-retrust request is pending for a session.
            let requestID = manager.requestSessionHostRetrust(
                session: session,
                server: server,
                onCompleted: { results.append($0) }
            )
            await gate.waitForCallCount(1)

            // When the owning session closes before trusted-host mutation and
            // reconnect work returns.
            await manager.closeSessionAndWait(session)
            await manager.waitForSessionHostRetrustRequest(requestID)

            // Then the pending request is treated as lifecycle cancellation
            // and presentation callbacks receive a non-reconnect result.
            #expect(manager.pendingSessionHostRetrustRequestIDs.isEmpty)
            #expect(results == [false])
            await gate.release()
            try? await Task.sleep(for: .milliseconds(20))
            #expect(
                results == [false],
                "A canceled session retrust request must not send a later success callback after blocked work returns."
            )
        }
    }

    @Test
    func connectionManagerRecordsMoshInstallFailureWithoutCallingSuccess() async {
        await withCleanConnectionManager { manager in
            let session = ConnectionSession(serverId: UUID(), title: "Session")
            manager.sessions = [session]
            manager.setMoshInstallAndReconnectOperationForTesting { _ in
                throw TestMoshInstallError.failed
            }
            var completedCount = 0
            var failedErrors: [String] = []

            // Given a manager-owned mosh install request whose install work
            // fails as an ordinary error.
            let requestID = manager.requestMoshInstallAndReconnect(
                session: session,
                onCompleted: { completedCount += 1 },
                onFailed: { failedErrors.append($0.localizedDescription) }
            )

            // When the request finishes.
            await manager.waitForMoshInstallRequest(requestID)

            // Then the failure remains distinguishable from success and the
            // request no longer appears pending.
            #expect(completedCount == 0)
            #expect(failedErrors == [TestMoshInstallError.failed.localizedDescription])
            #expect(
                manager.lastMoshInstallFailure?.localizedDescription == TestMoshInstallError.failed.localizedDescription,
                "The application layer should preserve the mosh install failure for diagnostics."
            )
            #expect(manager.pendingMoshInstallRequestIDs.isEmpty)
        }
    }

    @Test
    func tabManagerCoalescesPaneInstallRequestsUntilOperationsComplete() async {
        await withCleanTabManager { manager in
            let tab = TerminalTab(serverId: UUID(), title: "Tab")
            let tmuxGate = InstallRequestOperationGate()
            let moshGate = InstallRequestOperationGate()
            manager.tabsByServer[tab.serverId] = [tab]
            manager.paneStates[tab.rootPaneId] = TerminalPaneState(
                paneId: tab.rootPaneId,
                tabId: tab.id,
                serverId: tab.serverId
            )
            manager.setTmuxInstallOperationForTesting { paneId in
                #expect(paneId == tab.rootPaneId)
                await tmuxGate.run()
            }
            manager.setMoshInstallAndReconnectOperationForTesting { paneId in
                #expect(paneId == tab.rootPaneId)
                await moshGate.run()
            }
            var moshCompletedCount = 0

            // Given split terminal UI sends pane install intent to the
            // application layer.
            let tmuxRequestID = manager.requestTmuxInstall(for: tab.rootPaneId)
            let duplicateTmuxRequestID = manager.requestTmuxInstall(for: tab.rootPaneId)
            let moshRequestID = manager.requestMoshInstallAndReconnect(
                for: tab.rootPaneId,
                onCompleted: { moshCompletedCount += 1 },
                onFailed: { _ in }
            )

            // When both install operations are still blocked.
            #expect(duplicateTmuxRequestID == tmuxRequestID)
            #expect(manager.pendingTmuxInstallRequestIDs == [tmuxRequestID])
            #expect(manager.pendingMoshInstallRequestIDs == [moshRequestID])
            #expect(moshCompletedCount == 0)

            // Then each tracked pane request clears after its manager-owned
            // operation finishes.
            await tmuxGate.release()
            await moshGate.release()
            await manager.waitForTmuxInstallRequest(tmuxRequestID)
            await manager.waitForMoshInstallRequest(moshRequestID)

            #expect(manager.pendingTmuxInstallRequestIDs.isEmpty)
            #expect(manager.pendingMoshInstallRequestIDs.isEmpty)
            #expect(moshCompletedCount == 1)
        }
    }

    @Test
    func tabManagerClosePaneCancelsPendingInstallRequestsAndFinishesMoshCleanup() async {
        await withCleanTabManager { manager in
            let tab = TerminalTab(serverId: UUID(), title: "Tab")
            let tmuxGate = InstallRequestOperationGate()
            let moshGate = InstallRequestOperationGate()
            manager.tabsByServer[tab.serverId] = [tab]
            manager.paneStates[tab.rootPaneId] = TerminalPaneState(
                paneId: tab.rootPaneId,
                tabId: tab.id,
                serverId: tab.serverId
            )
            manager.setTmuxInstallOperationForTesting { _ in
                await tmuxGate.run()
            }
            manager.setMoshInstallAndReconnectOperationForTesting { _ in
                await moshGate.run()
            }
            var moshCompletedCount = 0
            var moshFailedCount = 0

            // Given tmux and mosh install requests are pending for a pane.
            let tmuxRequestID = manager.requestTmuxInstall(for: tab.rootPaneId)
            let moshRequestID = manager.requestMoshInstallAndReconnect(
                for: tab.rootPaneId,
                onCompleted: { moshCompletedCount += 1 },
                onFailed: { _ in moshFailedCount += 1 }
            )
            await tmuxGate.waitForCallCount(1)
            await moshGate.waitForCallCount(1)

            // When the owning pane closes before install work returns.
            await manager.closePaneAndWait(tab: tab, paneId: tab.rootPaneId)
            await manager.waitForTmuxInstallRequest(tmuxRequestID)
            await manager.waitForMoshInstallRequest(moshRequestID)

            // Then pending install request state should clear and mosh UI
            // cleanup should run as cancellation completion, not failure.
            #expect(manager.pendingTmuxInstallRequestIDs.isEmpty)
            #expect(manager.pendingMoshInstallRequestIDs.isEmpty)
            #expect(moshCompletedCount == 1)
            #expect(moshFailedCount == 0)
            await tmuxGate.release()
            await moshGate.release()
        }
    }

    @Test
    func tabManagerClosePaneCancelsPendingHostRetrustRequest() async {
        await withCleanTabManager { manager in
            let server = makeServer()
            let tab = TerminalTab(serverId: server.id, title: server.name)
            let gate = InstallRequestOperationGate()
            manager.tabsByServer[server.id] = [tab]
            manager.paneStates[tab.rootPaneId] = TerminalPaneState(
                paneId: tab.rootPaneId,
                tabId: tab.id,
                serverId: server.id
            )
            manager.setPaneHostRetrustOperationForTesting { _, _ in
                await gate.run()
                return true
            }
            var results: [Bool] = []

            // Given a host-retrust request is pending for a pane.
            let requestID = manager.requestPaneHostRetrust(
                paneId: tab.rootPaneId,
                server: server,
                onCompleted: { results.append($0) }
            )
            await gate.waitForCallCount(1)

            // When the owning pane closes before retrust work returns.
            await manager.closePaneAndWait(tab: tab, paneId: tab.rootPaneId)
            await manager.waitForPaneHostRetrustRequest(requestID)

            // Then the request clears as lifecycle cancellation, not a later
            // successful reconnect callback.
            #expect(manager.pendingPaneHostRetrustRequestIDs.isEmpty)
            #expect(results == [false])
            await gate.release()
            try? await Task.sleep(for: .milliseconds(20))
            #expect(
                results == [false],
                "A canceled pane retrust request must not send a later success callback after blocked work returns."
            )
        }
    }
}

private enum TestMoshInstallError: LocalizedError {
    case failed

    var errorDescription: String? {
        "test install failed"
    }
}

private actor InstallRequestOperationGate {
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var callContinuations: [CheckedContinuation<Void, Never>] = []
    private var isReleased = false
    private(set) var callCount = 0

    func run() async {
        callCount += 1
        callContinuations.forEach { $0.resume() }
        callContinuations.removeAll()
        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitForCallCount(_ expectedCount: Int) async {
        guard callCount < expectedCount else { return }
        await withCheckedContinuation { continuation in
            callContinuations.append(continuation)
        }
    }

    func release() {
        isReleased = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}
