import Foundation
import Testing
@testable import Waterm

// Test Context:
// These tests protect terminal resize ownership for root sessions and split
// panes. SwiftUI representables and redraw code may provide terminal
// dimensions, but request tracking, missing-entity rejection, coalescing, and
// close cleanup must be owned by TerminalSessions application managers. Fakes
// here use DEBUG resize-operation seams and do not construct GhosttyTerminalView
// or open network connections. Update these tests only if terminal resize
// request ownership intentionally moves to another non-UI owner with equivalent
// coalescing and close-cancellation guarantees.
@Suite(.serialized)
@MainActor
struct TerminalResizeIntentTests {
    @Test
    func rootResizeRejectsInvalidSizeAndMissingSessionWithoutCreatingRequest() async {
        await withCleanConnectionManager { manager in
            let session = ConnectionSession(
                serverId: UUID(),
                title: "Tencent",
                connectionState: .connected
            )

            let recorder = TerminalResizeRecorder()
            manager.setResizeOperationForTesting { size, entityId in
                recorder.recordSync("resize-\(entityId)-\(size.cols)x\(size.rows)")
            }

            // Given no matching session exists and one resize has invalid dimensions.
            let missingSessionRequestID = manager.requestSessionResize(
                TerminalResizeRequestSize(cols: 80, rows: 24),
                for: session.id
            )
            manager.sessions = [session]
            let invalidSizeRequestID = manager.requestSessionResize(
                TerminalResizeRequestSize(cols: 0, rows: 24),
                for: session.id
            )

            // Then the manager rejects both without creating resize work.
            #expect(missingSessionRequestID == nil)
            #expect(invalidSizeRequestID == nil)
            #expect(manager.pendingResizeRequestIDs.isEmpty)
            #expect(recorder.events.isEmpty)
        }
    }

    @Test
    func rootResizeRequestStaysTrackedUntilResizeCompletes() async {
        await withCleanConnectionManager { manager in
            let session = ConnectionSession(
                serverId: UUID(),
                title: "Tencent",
                connectionState: .connected
            )
            manager.sessions = [session]

            let recorder = TerminalResizeRecorder()
            let gate = TerminalResizeGate()
            manager.setResizeOperationForTesting { size, entityId in
                recorder.recordSync("start-\(entityId)-\(size.cols)x\(size.rows)")
                await gate.wait()
                recorder.recordSync("end-\(size.cols)x\(size.rows)")
            }

            // When a resize callback sends intent for the session.
            let requestID = try! #require(
                manager.requestSessionResize(
                    TerminalResizeRequestSize(cols: 80, rows: 24),
                    for: session.id
                )
            )
            await recorder.waitForCount(1)

            // Then the request remains tracked while the resize operation is blocked.
            #expect(manager.pendingResizeRequestIDs == [requestID])

            await gate.open()
            await manager.waitForResizeRequest(requestID)

            // And the manager clears bookkeeping after completion.
            #expect(
                recorder.events == [
                    "start-session(\(session.id))-80x24",
                    "end-80x24"
                ]
            )
            #expect(manager.pendingResizeRequestIDs.isEmpty)
        }
    }

    @Test
    func rootResizeRequestsCoalesceToLatestSizeBeforeRunning() async {
        await withCleanConnectionManager { manager in
            let session = ConnectionSession(
                serverId: UUID(),
                title: "Tencent",
                connectionState: .connected
            )
            manager.sessions = [session]

            let recorder = TerminalResizeRecorder()
            manager.setResizeOperationForTesting { size, entityId in
                recorder.recordSync("resize-\(entityId)-\(size.cols)x\(size.rows)")
            }

            // When two resize callbacks arrive before the manager-owned task runs.
            let firstRequestID = try! #require(
                manager.requestSessionResize(
                    TerminalResizeRequestSize(cols: 80, rows: 24),
                    for: session.id
                )
            )
            let secondRequestID = try! #require(
                manager.requestSessionResize(
                    TerminalResizeRequestSize(cols: 120, rows: 40),
                    for: session.id
                )
            )
            await manager.waitForResizeRequest(firstRequestID)

            // Then both callbacks share one tracked request and only the latest size is applied.
            #expect(firstRequestID == secondRequestID)
            #expect(
                recorder.events == ["resize-session(\(session.id))-120x40"],
                "Rapid resize callbacks should coalesce to the latest dimensions."
            )
            #expect(manager.pendingResizeRequestIDs.isEmpty)
        }
    }

    @Test
    func rootResizeRequestAppliesLatestSizeThatArrivesWhileResizeIsRunning() async {
        await withCleanConnectionManager { manager in
            let session = ConnectionSession(
                serverId: UUID(),
                title: "Tencent",
                connectionState: .connected
            )
            manager.sessions = [session]

            let recorder = TerminalResizeRecorder()
            let gate = TerminalResizeGate()
            manager.setResizeOperationForTesting { size, entityId in
                recorder.recordSync("start-\(entityId)-\(size.cols)x\(size.rows)")
                await gate.wait()
                recorder.recordSync("end-\(size.cols)x\(size.rows)")
            }

            // Given the first resize is already running.
            let firstRequestID = try! #require(
                manager.requestSessionResize(
                    TerminalResizeRequestSize(cols: 80, rows: 24),
                    for: session.id
                )
            )
            await recorder.waitForCount(1)

            // When a newer terminal size arrives before the first operation returns.
            let secondRequestID = try! #require(
                manager.requestSessionResize(
                    TerminalResizeRequestSize(cols: 120, rows: 40),
                    for: session.id
                )
            )

            // Then the request stays coalesced but applies the latest size before clearing.
            #expect(firstRequestID == secondRequestID)
            await gate.open()
            await manager.waitForResizeRequest(firstRequestID)
            #expect(
                recorder.events == [
                    "start-session(\(session.id))-80x24",
                    "end-80x24",
                    "start-session(\(session.id))-120x40",
                    "end-120x40"
                ],
                "A resize that arrives while the prior resize is running must not be lost."
            )
        }
    }

    @Test
    func rootResizeRequestIsClearedWhenSessionCloses() async {
        await withCleanConnectionManager { manager in
            let session = ConnectionSession(
                serverId: UUID(),
                title: "Tencent",
                connectionState: .connected
            )
            manager.sessions = [session]

            let recorder = TerminalResizeRecorder()
            let gate = TerminalResizeGate()
            manager.setResizeOperationForTesting { size, _ in
                recorder.recordSync("start-\(size.cols)x\(size.rows)")
                await gate.wait()
                recorder.recordSync("end-\(size.cols)x\(size.rows)")
            }

            // Given a resize request is running.
            let requestID = try! #require(
                manager.requestSessionResize(
                    TerminalResizeRequestSize(cols: 80, rows: 24),
                    for: session.id
                )
            )
            await recorder.waitForCount(1)

            // When the real session close path completes.
            await manager.closeSessionAndWait(session)

            // Then close owns cancellation/cleanup for pending resize requests.
            #expect(
                manager.pendingResizeRequestIDs.isEmpty,
                "Closing a session must clear manager-owned resize request bookkeeping."
            )

            await gate.open()
            await manager.waitForResizeRequest(requestID)
        }
    }

    @Test
    func paneResizeRejectsInvalidSizeAndMissingPaneWithoutCreatingRequest() async {
        await withCleanTabManager { manager in
            let tab = TerminalTab(serverId: UUID(), title: "Tencent")

            let recorder = TerminalResizeRecorder()
            manager.setResizeOperationForTesting { size, entityId in
                recorder.recordSync("resize-\(entityId)-\(size.cols)x\(size.rows)")
            }

            // Given no matching pane exists and one resize has invalid dimensions.
            let missingPaneRequestID = manager.requestPaneResize(
                TerminalResizeRequestSize(cols: 100, rows: 32),
                forPane: tab.rootPaneId
            )
            manager.tabsByServer[tab.serverId] = [tab]
            manager.selectedTabByServer[tab.serverId] = tab.id
            manager.paneStates[tab.rootPaneId] = TerminalPaneState(
                paneId: tab.rootPaneId,
                tabId: tab.id,
                serverId: tab.serverId
            )
            let invalidSizeRequestID = manager.requestPaneResize(
                TerminalResizeRequestSize(cols: 100, rows: -1),
                forPane: tab.rootPaneId
            )

            // Then the manager rejects both without creating resize work.
            #expect(missingPaneRequestID == nil)
            #expect(invalidSizeRequestID == nil)
            #expect(manager.pendingResizeRequestIDs.isEmpty)
            #expect(recorder.events.isEmpty)
        }
    }

    @Test
    func paneResizeRequestStaysTrackedUntilResizeCompletes() async {
        await withCleanTabManager { manager in
            let tab = TerminalTab(serverId: UUID(), title: "Tencent")
            manager.tabsByServer[tab.serverId] = [tab]
            manager.selectedTabByServer[tab.serverId] = tab.id
            manager.paneStates[tab.rootPaneId] = TerminalPaneState(
                paneId: tab.rootPaneId,
                tabId: tab.id,
                serverId: tab.serverId
            )

            let recorder = TerminalResizeRecorder()
            let gate = TerminalResizeGate()
            manager.setResizeOperationForTesting { size, entityId in
                recorder.recordSync("start-\(entityId)-\(size.cols)x\(size.rows)")
                await gate.wait()
                recorder.recordSync("end-\(size.cols)x\(size.rows)")
            }

            // When a resize callback sends intent for the pane.
            let requestID = try! #require(
                manager.requestPaneResize(
                    TerminalResizeRequestSize(cols: 100, rows: 32),
                    forPane: tab.rootPaneId
                )
            )
            await recorder.waitForCount(1)

            // Then the request remains tracked while the resize operation is blocked.
            #expect(manager.pendingResizeRequestIDs == [requestID])

            await gate.open()
            await manager.waitForResizeRequest(requestID)

            // And the manager clears bookkeeping after completion.
            #expect(
                recorder.events == [
                    "start-pane(\(tab.rootPaneId))-100x32",
                    "end-100x32"
                ]
            )
            #expect(manager.pendingResizeRequestIDs.isEmpty)
        }
    }

    @Test
    func paneResizeRequestsCoalesceToLatestSizeBeforeRunning() async {
        await withCleanTabManager { manager in
            let tab = TerminalTab(serverId: UUID(), title: "Tencent")
            manager.tabsByServer[tab.serverId] = [tab]
            manager.selectedTabByServer[tab.serverId] = tab.id
            manager.paneStates[tab.rootPaneId] = TerminalPaneState(
                paneId: tab.rootPaneId,
                tabId: tab.id,
                serverId: tab.serverId
            )

            let recorder = TerminalResizeRecorder()
            manager.setResizeOperationForTesting { size, entityId in
                recorder.recordSync("resize-\(entityId)-\(size.cols)x\(size.rows)")
            }

            // When two resize callbacks arrive before the manager-owned task runs.
            let firstRequestID = try! #require(
                manager.requestPaneResize(
                    TerminalResizeRequestSize(cols: 80, rows: 24),
                    forPane: tab.rootPaneId
                )
            )
            let secondRequestID = try! #require(
                manager.requestPaneResize(
                    TerminalResizeRequestSize(cols: 120, rows: 40),
                    forPane: tab.rootPaneId
                )
            )
            await manager.waitForResizeRequest(firstRequestID)

            // Then both callbacks share one tracked request and only the latest size is applied.
            #expect(firstRequestID == secondRequestID)
            #expect(
                recorder.events == ["resize-pane(\(tab.rootPaneId))-120x40"],
                "Rapid pane resize callbacks should coalesce to the latest dimensions."
            )
            #expect(manager.pendingResizeRequestIDs.isEmpty)
        }
    }

    @Test
    func paneResizeRequestAppliesLatestSizeThatArrivesWhileResizeIsRunning() async {
        await withCleanTabManager { manager in
            let tab = TerminalTab(serverId: UUID(), title: "Tencent")
            manager.tabsByServer[tab.serverId] = [tab]
            manager.selectedTabByServer[tab.serverId] = tab.id
            manager.paneStates[tab.rootPaneId] = TerminalPaneState(
                paneId: tab.rootPaneId,
                tabId: tab.id,
                serverId: tab.serverId
            )

            let recorder = TerminalResizeRecorder()
            let gate = TerminalResizeGate()
            manager.setResizeOperationForTesting { size, entityId in
                recorder.recordSync("start-\(entityId)-\(size.cols)x\(size.rows)")
                await gate.wait()
                recorder.recordSync("end-\(size.cols)x\(size.rows)")
            }

            // Given the first pane resize is already running.
            let firstRequestID = try! #require(
                manager.requestPaneResize(
                    TerminalResizeRequestSize(cols: 100, rows: 32),
                    forPane: tab.rootPaneId
                )
            )
            await recorder.waitForCount(1)

            // When a newer pane size arrives before the first operation returns.
            let secondRequestID = try! #require(
                manager.requestPaneResize(
                    TerminalResizeRequestSize(cols: 132, rows: 48),
                    forPane: tab.rootPaneId
                )
            )

            // Then the request stays coalesced but applies the latest size before clearing.
            #expect(firstRequestID == secondRequestID)
            await gate.open()
            await manager.waitForResizeRequest(firstRequestID)
            #expect(
                recorder.events == [
                    "start-pane(\(tab.rootPaneId))-100x32",
                    "end-100x32",
                    "start-pane(\(tab.rootPaneId))-132x48",
                    "end-132x48"
                ],
                "A pane resize that arrives while the prior resize is running must not be lost."
            )
        }
    }

    @Test
    func paneResizeRequestIsClearedWhenPaneCloses() async {
        await withCleanTabManager { manager in
            let tab = TerminalTab(serverId: UUID(), title: "Tencent")
            manager.tabsByServer[tab.serverId] = [tab]
            manager.selectedTabByServer[tab.serverId] = tab.id
            manager.paneStates[tab.rootPaneId] = TerminalPaneState(
                paneId: tab.rootPaneId,
                tabId: tab.id,
                serverId: tab.serverId
            )

            let recorder = TerminalResizeRecorder()
            let gate = TerminalResizeGate()
            manager.setResizeOperationForTesting { size, _ in
                recorder.recordSync("start-\(size.cols)x\(size.rows)")
                await gate.wait()
                recorder.recordSync("end-\(size.cols)x\(size.rows)")
            }

            // Given a resize request is running.
            let requestID = try! #require(
                manager.requestPaneResize(
                    TerminalResizeRequestSize(cols: 100, rows: 32),
                    forPane: tab.rootPaneId
                )
            )
            await recorder.waitForCount(1)

            // When the real pane close path completes.
            await manager.closePaneAndWait(tab: tab, paneId: tab.rootPaneId)

            // Then close owns cancellation/cleanup for pending resize requests.
            #expect(
                manager.pendingResizeRequestIDs.isEmpty,
                "Closing a pane must clear manager-owned resize request bookkeeping."
            )

            await gate.open()
            await manager.waitForResizeRequest(requestID)
        }
    }

    private func withCleanConnectionManager(
        _ body: @MainActor (ConnectionSessionManager) async -> Void
    ) async {
        let manager = ConnectionSessionManager.shared
        await manager.resetForTesting()
        await body(manager)
        await manager.resetForTesting()
    }

    private func withCleanTabManager(
        _ body: @MainActor (TerminalTabManager) async -> Void
    ) async {
        let manager = TerminalTabManager.shared
        await manager.resetForTesting()
        await body(manager)
        await manager.resetForTesting()
    }
}

@MainActor
private final class TerminalResizeRecorder {
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

private actor TerminalResizeGate {
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
