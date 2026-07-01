import Foundation
import Testing
@testable import Waterm

// Test Context:
// These tests protect terminal process-exit ownership for root sessions and
// split panes. Terminal UI may receive `onProcessExit` from Ghostty surfaces,
// but request tracking, duplicate coalescing, and close cancellation must be
// owned by TerminalSessions application managers. Fakes use DEBUG process-exit
// seams and do not construct GhosttyTerminalView or open network connections.
// Update these tests only if process-exit orchestration intentionally moves to
// another non-UI owner with equivalent tracking and close-cancellation rules.
@Suite(.serialized)
@MainActor
struct TerminalProcessExitIntentTests {
    @Test
    func rootProcessExitRejectsMissingSessionWithoutCreatingRequest() async {
        await withCleanConnectionManager { manager in
            let sessionId = UUID()
            let recorder = TerminalProcessExitRecorder()
            manager.setProcessExitOperationForTesting { entityId in
                recorder.recordSync("exit-\(entityId)")
            }

            // Given no matching root session exists.
            let requestID = manager.requestSessionProcessExit(forSession: sessionId)

            // Then the manager rejects the process-exit intent without creating work.
            #expect(requestID == nil)
            #expect(manager.pendingProcessExitRequestIDs.isEmpty)
            #expect(recorder.events.isEmpty)
        }
    }

    @Test
    func rootProcessExitRequestStaysTrackedUntilOperationCompletes() async {
        await withCleanConnectionManager { manager in
            let session = ConnectionSession(
                serverId: UUID(),
                title: "Tencent",
                connectionState: .connected
            )
            manager.sessions = [session]

            let recorder = TerminalProcessExitRecorder()
            let gate = TerminalProcessExitGate()
            manager.setProcessExitOperationForTesting { entityId in
                recorder.recordSync("start-\(entityId)")
                await gate.wait()
                recorder.recordSync("end-\(entityId)")
            }

            // When a root process-exit callback sends intent.
            let requestID = try! #require(
                manager.requestSessionProcessExit(forSession: session.id)
            )
            await recorder.waitForCount(1)

            // Then the manager keeps the request tracked while exit handling is blocked.
            #expect(manager.pendingProcessExitRequestIDs == [requestID])

            await gate.open()
            await manager.waitForProcessExitRequest(requestID)

            // And the manager clears bookkeeping after completion.
            #expect(
                recorder.events == [
                    "start-session(\(session.id))",
                    "end-session(\(session.id))"
                ]
            )
            #expect(manager.pendingProcessExitRequestIDs.isEmpty)
        }
    }

    @Test
    func duplicateRootProcessExitRequestsCoalesceToOneOperation() async {
        await withCleanConnectionManager { manager in
            let session = ConnectionSession(
                serverId: UUID(),
                title: "Tencent",
                connectionState: .connected
            )
            manager.sessions = [session]

            let recorder = TerminalProcessExitRecorder()
            manager.setProcessExitOperationForTesting { entityId in
                recorder.recordSync("exit-\(entityId)")
            }

            // When the same session reports process exit twice before the request task runs.
            let firstRequestID = try! #require(
                manager.requestSessionProcessExit(forSession: session.id)
            )
            let secondRequestID = try! #require(
                manager.requestSessionProcessExit(forSession: session.id)
            )
            await manager.waitForProcessExitRequest(firstRequestID)

            // Then both callbacks share one tracked request and run exit handling once.
            #expect(firstRequestID == secondRequestID)
            #expect(
                recorder.events == ["exit-session(\(session.id))"],
                "Duplicate root process-exit callbacks should not queue duplicate teardown work."
            )
            #expect(manager.pendingProcessExitRequestIDs.isEmpty)
        }
    }

    @Test
    func rootProcessExitRequestIsClearedWhenSessionCloses() async {
        await withCleanConnectionManager { manager in
            let session = ConnectionSession(
                serverId: UUID(),
                title: "Tencent",
                connectionState: .connected
            )
            manager.sessions = [session]

            let recorder = TerminalProcessExitRecorder()
            let gate = TerminalProcessExitGate()
            manager.setProcessExitOperationForTesting { entityId in
                recorder.recordSync("start-\(entityId)")
                await gate.wait()
                recorder.recordSync("end-\(entityId)")
            }

            // Given a root process-exit request is running.
            let requestID = try! #require(
                manager.requestSessionProcessExit(forSession: session.id)
            )
            await recorder.waitForCount(1)

            // When the real session close path completes.
            await manager.closeSessionAndWait(session)

            // Then close owns cancellation/cleanup for pending process-exit requests.
            #expect(
                manager.pendingProcessExitRequestIDs.isEmpty,
                "Closing a session must clear manager-owned process-exit request bookkeeping."
            )

            await gate.open()
            await manager.waitForProcessExitRequest(requestID)
        }
    }

    @Test
    func rootShellExitTracksSSHUnregisterUntilCleanupFinishes() async {
        await withCleanConnectionManager { manager in
            let serverId = UUID()
            let session = ConnectionSession(
                serverId: serverId,
                title: "Exited Shell",
                connectionState: .connected
            )
            manager.sessions = [session]
            manager.updateSessionState(session.id, to: .connected)
            manager.registerSSHClient(
                SSHClient(),
                shellId: UUID(),
                for: session.id,
                serverId: serverId,
                skipTmuxLifecycle: true
            )

            // When Ghostty reports that the root session process exited.
            manager.handleShellExit(for: session.id)

            // Then SSH unregister cleanup is tracked so a same-server reopen can wait for it.
            #expect(
                manager.serverTeardownTaskStore.count(forServer: serverId) == 1,
                "Process-exit cleanup must be tracked by server so open/reconnect waits for old shell teardown."
            )

            await manager.waitForServerTeardownTasks(serverId)

            #expect(manager.serverTeardownTaskStore.count(forServer: serverId) == 0)
            #expect(manager.shellId(for: session.id) == nil)
        }
    }

    @Test
    func paneProcessExitRejectsMissingPaneWithoutCreatingRequest() async {
        await withCleanTabManager { manager in
            let paneId = UUID()
            let recorder = TerminalProcessExitRecorder()
            manager.setProcessExitOperationForTesting { entityId in
                recorder.recordSync("exit-\(entityId)")
            }

            // Given no matching pane exists.
            let requestID = manager.requestPaneProcessExit(forPane: paneId)

            // Then the manager rejects the process-exit intent without creating work.
            #expect(requestID == nil)
            #expect(manager.pendingProcessExitRequestIDs.isEmpty)
            #expect(recorder.events.isEmpty)
        }
    }

    @Test
    func paneProcessExitRequestStaysTrackedUntilOperationCompletes() async {
        await withCleanTabManager { manager in
            let tab = TerminalTab(serverId: UUID(), title: "Tencent")
            manager.installTestPaneState(for: tab)

            let recorder = TerminalProcessExitRecorder()
            let gate = TerminalProcessExitGate()
            manager.setProcessExitOperationForTesting { entityId in
                recorder.recordSync("start-\(entityId)")
                await gate.wait()
                recorder.recordSync("end-\(entityId)")
            }

            // When a pane process-exit callback sends intent.
            let requestID = try! #require(
                manager.requestPaneProcessExit(forPane: tab.rootPaneId)
            )
            await recorder.waitForCount(1)

            // Then the manager keeps the request tracked while exit handling is blocked.
            #expect(manager.pendingProcessExitRequestIDs == [requestID])

            await gate.open()
            await manager.waitForProcessExitRequest(requestID)

            // And the manager clears bookkeeping after completion.
            #expect(
                recorder.events == [
                    "start-pane(\(tab.rootPaneId))",
                    "end-pane(\(tab.rootPaneId))"
                ]
            )
            #expect(manager.pendingProcessExitRequestIDs.isEmpty)
        }
    }

    @Test
    func duplicatePaneProcessExitRequestsCoalesceToOneOperation() async {
        await withCleanTabManager { manager in
            let tab = TerminalTab(serverId: UUID(), title: "Tencent")
            manager.installTestPaneState(for: tab)

            let recorder = TerminalProcessExitRecorder()
            manager.setProcessExitOperationForTesting { entityId in
                recorder.recordSync("exit-\(entityId)")
            }

            // When the same pane reports process exit twice before the request task runs.
            let firstRequestID = try! #require(
                manager.requestPaneProcessExit(forPane: tab.rootPaneId)
            )
            let secondRequestID = try! #require(
                manager.requestPaneProcessExit(forPane: tab.rootPaneId)
            )
            await manager.waitForProcessExitRequest(firstRequestID)

            // Then both callbacks share one tracked request and run exit handling once.
            #expect(firstRequestID == secondRequestID)
            #expect(
                recorder.events == ["exit-pane(\(tab.rootPaneId))"],
                "Duplicate pane process-exit callbacks should not queue duplicate teardown work."
            )
            #expect(manager.pendingProcessExitRequestIDs.isEmpty)
        }
    }

    @Test
    func paneProcessExitRequestIsClearedWhenPaneCloses() async {
        await withCleanTabManager { manager in
            let tab = TerminalTab(serverId: UUID(), title: "Tencent")
            manager.installTestPaneState(for: tab)

            let recorder = TerminalProcessExitRecorder()
            let gate = TerminalProcessExitGate()
            manager.setProcessExitOperationForTesting { entityId in
                recorder.recordSync("start-\(entityId)")
                await gate.wait()
                recorder.recordSync("end-\(entityId)")
            }

            // Given a pane process-exit request is running.
            let requestID = try! #require(
                manager.requestPaneProcessExit(forPane: tab.rootPaneId)
            )
            await recorder.waitForCount(1)

            // When the real pane close path completes.
            await manager.closePaneAndWait(tab: tab, paneId: tab.rootPaneId)

            // Then close owns cancellation/cleanup for pending process-exit requests.
            #expect(
                manager.pendingProcessExitRequestIDs.isEmpty,
                "Closing a pane must clear manager-owned process-exit request bookkeeping."
            )

            await gate.open()
            await manager.waitForProcessExitRequest(requestID)
        }
    }

    private func withCleanTabManager(
        _ body: @MainActor (TerminalTabManager) async -> Void
    ) async {
        let manager = TerminalTabManager.shared
        await manager.resetForTesting()
        await body(manager)
        await manager.resetForTesting()
    }

    private func withCleanConnectionManager(
        _ body: @MainActor (ConnectionSessionManager) async -> Void
    ) async {
        let manager = ConnectionSessionManager.shared
        await manager.resetForTesting()
        await body(manager)
        await manager.resetForTesting()
    }
}

private extension TerminalTabManager {
    func installTestPaneState(for tab: TerminalTab) {
        tabsByServer[tab.serverId] = [tab]
        selectedTabByServer[tab.serverId] = tab.id
        paneStates[tab.rootPaneId] = TerminalPaneState(
            paneId: tab.rootPaneId,
            tabId: tab.id,
            serverId: tab.serverId
        )
    }
}

@MainActor
private final class TerminalProcessExitRecorder {
    private(set) var events: [String] = []

    func recordSync(_ event: String) {
        events.append(event)
    }

    func waitForCount(_ count: Int) async {
        while events.count < count {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}

private actor TerminalProcessExitGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}
