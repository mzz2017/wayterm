import Foundation
import Testing
@testable import VVTerm

// Test Context:
// These tests protect the automatic tmux lifecycle launched after shell registration.
// The invariant is that shell registration must not fire-and-forget tmux attach work:
// it should be tracked by the TerminalSessions application layer and canceled when
// the owning session or pane closes. Update these tests only if tmux lifecycle
// ownership moves to a different explicit request owner with equivalent wait/cancel
// semantics.

@Suite(.serialized)
@MainActor
struct TerminalTmuxLifecycleRequestTests {
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
    func connectionManagerTracksTmuxLifecycleRequestUntilOperationCompletes() async throws {
        try await withCleanConnectionManager { manager in
            let serverId = UUID()
            let shellId = UUID()
            let session = ConnectionSession(serverId: serverId, title: "Tracked tmux")
            let gate = TmuxLifecycleGate()
            manager.sessions = [session]
            manager.setTmuxLifecycleOperationForTesting { requestSessionId, requestServerId, requestShellId in
                #expect(requestSessionId == session.id)
                #expect(requestServerId == serverId)
                #expect(requestShellId == shellId)
                await gate.run()
            }

            manager.registerSSHClient(
                SSHClient(),
                shellId: shellId,
                for: session.id,
                serverId: serverId
            )

            await gate.waitForCallCount(1)
            let requestID = try #require(manager.pendingTmuxLifecycleRequestIDs.first)
            #expect(
                manager.pendingTmuxLifecycleRequestIDs == [requestID],
                "Automatic tmux lifecycle should remain pending while its application request is blocked."
            )

            await gate.release()
            await manager.waitForTmuxLifecycleRequest(requestID)

            #expect(
                manager.pendingTmuxLifecycleRequestIDs.isEmpty,
                "Automatic tmux lifecycle request state should clear after the tracked operation completes."
            )
        }
    }

    @Test
    func connectionManagerCloseSessionCancelsPendingTmuxLifecycleRequest() async {
        await withCleanConnectionManager { manager in
            let serverId = UUID()
            let shellId = UUID()
            let session = ConnectionSession(serverId: serverId, title: "Close tmux")
            let gate = TmuxLifecycleGate()
            manager.sessions = [session]
            manager.setTmuxLifecycleOperationForTesting { _, _, _ in
                await gate.run()
            }

            manager.registerSSHClient(
                SSHClient(),
                shellId: shellId,
                for: session.id,
                serverId: serverId
            )
            await gate.waitForCallCount(1)

            await manager.closeSessionAndWait(session, notingSessionEnd: false)

            #expect(manager.pendingTmuxLifecycleRequestIDs.isEmpty)
            await gate.release()
            await gate.waitForReturn()
            #expect(
                await gate.wasCancelledOnReturn,
                "Closing a session should cancel the automatic tmux lifecycle task that belongs to its shell."
            )
        }
    }

    @Test
    func tabManagerTracksTmuxLifecycleRequestUntilOperationCompletes() async throws {
        try await withCleanTabManager { manager in
            let serverId = UUID()
            let shellId = UUID()
            let tab = TerminalTab(serverId: serverId, title: "Tracked pane tmux")
            let gate = TmuxLifecycleGate()
            manager.tabsByServer[serverId] = [tab]
            manager.paneStates[tab.rootPaneId] = TerminalPaneState(
                paneId: tab.rootPaneId,
                tabId: tab.id,
                serverId: serverId
            )
            manager.setTmuxLifecycleOperationForTesting { requestPaneId, requestServerId, requestShellId in
                #expect(requestPaneId == tab.rootPaneId)
                #expect(requestServerId == serverId)
                #expect(requestShellId == shellId)
                await gate.run()
            }

            manager.registerSSHClient(
                SSHClient(),
                shellId: shellId,
                for: tab.rootPaneId,
                serverId: serverId
            )

            await gate.waitForCallCount(1)
            let requestID = try #require(manager.pendingTmuxLifecycleRequestIDs.first)
            #expect(
                manager.pendingTmuxLifecycleRequestIDs == [requestID],
                "Automatic pane tmux lifecycle should remain pending while its application request is blocked."
            )

            await gate.release()
            await manager.waitForTmuxLifecycleRequest(requestID)

            #expect(manager.pendingTmuxLifecycleRequestIDs.isEmpty)
        }
    }

    @Test
    func tabManagerClosePaneCancelsPendingTmuxLifecycleRequest() async {
        await withCleanTabManager { manager in
            let serverId = UUID()
            let shellId = UUID()
            let tab = TerminalTab(serverId: serverId, title: "Close pane tmux")
            let gate = TmuxLifecycleGate()
            manager.tabsByServer[serverId] = [tab]
            manager.paneStates[tab.rootPaneId] = TerminalPaneState(
                paneId: tab.rootPaneId,
                tabId: tab.id,
                serverId: serverId
            )
            manager.setTmuxLifecycleOperationForTesting { _, _, _ in
                await gate.run()
            }

            manager.registerSSHClient(
                SSHClient(),
                shellId: shellId,
                for: tab.rootPaneId,
                serverId: serverId
            )
            await gate.waitForCallCount(1)

            await manager.closePaneAndWait(tab: tab, paneId: tab.rootPaneId)

            #expect(manager.pendingTmuxLifecycleRequestIDs.isEmpty)
            await gate.release()
            await gate.waitForReturn()
            #expect(
                await gate.wasCancelledOnReturn,
                "Closing a pane should cancel the automatic tmux lifecycle task that belongs to its shell."
            )
        }
    }
}

private actor TmuxLifecycleGate {
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var callContinuations: [CheckedContinuation<Void, Never>] = []
    private var returnContinuations: [CheckedContinuation<Void, Never>] = []
    private var isReleased = false
    private var didReturn = false
    private(set) var callCount = 0
    private(set) var wasCancelledOnReturn = false

    func run() async {
        callCount += 1
        callContinuations.forEach { $0.resume() }
        callContinuations.removeAll()
        if !isReleased {
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
            }
        }
        wasCancelledOnReturn = Task.isCancelled
        didReturn = true
        returnContinuations.forEach { $0.resume() }
        returnContinuations.removeAll()
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

    func waitForReturn() async {
        guard !didReturn else { return }
        await withCheckedContinuation { continuation in
            returnContinuations.append(continuation)
        }
    }
}
