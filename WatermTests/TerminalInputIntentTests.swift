import Foundation
import Testing
@testable import Waterm

// Test Context:
// These tests protect terminal keyboard input ownership for root sessions and
// split panes. SwiftUI representables may provide input bytes from
// GhosttyTerminalView.writeCallback, but request tracking, close/missing-entity
// rejection, and write ordering must be owned by TerminalSessions application
// managers. Fakes here use DEBUG input-operation seams and do not construct
// GhosttyTerminalView or open network connections. Update these tests only if
// terminal input request ownership intentionally moves to another non-UI owner
// with equivalent ordering guarantees.
@Suite(.serialized)
@MainActor
struct TerminalInputIntentTests {
    @Test
    func rootInputRejectsEmptyPayloadAndMissingSessionWithoutCreatingRequest() async {
        await withCleanConnectionManager { manager in
            let session = ConnectionSession(
                serverId: UUID(),
                title: "Tencent",
                connectionState: .connected
            )

            let recorder = TerminalInputRecorder()
            manager.setInputOperationForTesting { data, entityId in
                recorder.recordSync("input-\(entityId)-\(String(decoding: data, as: UTF8.self))")
            }

            // Given no matching session exists and one payload is empty.
            let missingSessionRequestID = manager.requestSessionInput(
                Data("pwd\n".utf8),
                to: session.id
            )
            manager.sessions = [session]
            let emptyPayloadRequestID = manager.requestSessionInput(Data(), to: session.id)

            // Then the manager rejects both without creating background input work.
            #expect(missingSessionRequestID == nil)
            #expect(emptyPayloadRequestID == nil)
            #expect(manager.pendingInputRequestIDs.isEmpty)
            #expect(recorder.events.isEmpty)
        }
    }

    @Test
    func rootInputRequestsStayTrackedAndPreserveWriteOrder() async {
        await withCleanConnectionManager { manager in
            let session = ConnectionSession(
                serverId: UUID(),
                title: "Tencent",
                connectionState: .connected
            )
            manager.sessions = [session]

            let recorder = TerminalInputRecorder()
            let gate = TerminalInputGate()
            manager.setInputOperationForTesting { data, entityId in
                let payload = String(decoding: data, as: UTF8.self)
                recorder.recordSync("start-\(entityId)-\(payload)")
                if payload == "a" {
                    await gate.wait()
                }
                recorder.recordSync("end-\(payload)")
            }

            // When two rapid write callbacks send input to the same session.
            let firstRequestID = try! #require(
                manager.requestSessionInput(Data("a".utf8), to: session.id)
            )
            await recorder.waitForCount(1)
            let secondRequestID = try! #require(
                manager.requestSessionInput(Data("b".utf8), to: session.id)
            )

            // Then both requests are tracked while the first write is blocked.
            #expect(manager.pendingInputRequestIDs == [firstRequestID, secondRequestID])
            #expect(recorder.events == ["start-session(\(session.id))-a"])

            await gate.open()
            await manager.waitForInputRequest(firstRequestID)
            await manager.waitForInputRequest(secondRequestID)

            // And the application manager preserves terminal write ordering.
            #expect(
                recorder.events == [
                    "start-session(\(session.id))-a",
                    "end-a",
                    "start-session(\(session.id))-b",
                    "end-b"
                ],
                "Rapid input must be serialized by the manager instead of racing UI-owned tasks."
            )
            #expect(manager.pendingInputRequestIDs.isEmpty)
        }
    }

    @Test
    func rootInputQueuedAfterSessionRemovalIsDroppedBeforeSending() async {
        await withCleanConnectionManager { manager in
            let session = ConnectionSession(
                serverId: UUID(),
                title: "Tencent",
                connectionState: .connected
            )
            manager.sessions = [session]

            let recorder = TerminalInputRecorder()
            let gate = TerminalInputGate()
            manager.setInputOperationForTesting { data, _ in
                let payload = String(decoding: data, as: UTF8.self)
                recorder.recordSync("start-\(payload)")
                if payload == "first" {
                    await gate.wait()
                }
                recorder.recordSync("end-\(payload)")
            }

            // Given one input is running and another is queued behind it.
            let firstRequestID = try! #require(
                manager.requestSessionInput(Data("first".utf8), to: session.id)
            )
            await recorder.waitForCount(1)
            let secondRequestID = try! #require(
                manager.requestSessionInput(Data("second".utf8), to: session.id)
            )

            // When the session disappears before the queued input can run.
            manager.sessions.removeAll()
            await gate.open()
            await manager.waitForInputRequest(firstRequestID)
            await manager.waitForInputRequest(secondRequestID)

            // Then the queued input is dropped by the manager recheck.
            #expect(recorder.events == ["start-first", "end-first"])
            #expect(manager.pendingInputRequestIDs.isEmpty)
        }
    }

    @Test
    func rootInputRequestsAreClearedWhenSessionCloses() async {
        await withCleanConnectionManager { manager in
            let session = ConnectionSession(
                serverId: UUID(),
                title: "Tencent",
                connectionState: .connected
            )
            manager.sessions = [session]

            let recorder = TerminalInputRecorder()
            let gate = TerminalInputGate()
            manager.setInputOperationForTesting { data, _ in
                let payload = String(decoding: data, as: UTF8.self)
                recorder.recordSync("start-\(payload)")
                if payload == "first" {
                    await gate.wait()
                }
                recorder.recordSync("end-\(payload)")
            }

            // Given one input is running and another is queued behind it.
            let firstRequestID = try! #require(
                manager.requestSessionInput(Data("first".utf8), to: session.id)
            )
            await recorder.waitForCount(1)
            let secondRequestID = try! #require(
                manager.requestSessionInput(Data("second".utf8), to: session.id)
            )

            // When the real session close path completes.
            await manager.closeSessionAndWait(session)

            // Then close owns cancellation/cleanup for pending input requests.
            #expect(
                manager.pendingInputRequestIDs.isEmpty,
                "Closing a session must clear manager-owned input request bookkeeping."
            )

            await gate.open()
            await manager.waitForInputRequest(firstRequestID)
            await manager.waitForInputRequest(secondRequestID)
        }
    }

    @Test
    func paneInputRejectsEmptyPayloadAndMissingPaneWithoutCreatingRequest() async {
        await withCleanTabManager { manager in
            let tab = TerminalTab(serverId: UUID(), title: "Tencent")

            let recorder = TerminalInputRecorder()
            manager.setInputOperationForTesting { data, entityId in
                recorder.recordSync("input-\(entityId)-\(String(decoding: data, as: UTF8.self))")
            }

            // Given no matching pane exists and one payload is empty.
            let missingPaneRequestID = manager.requestPaneInput(
                Data("ls\n".utf8),
                toPane: tab.rootPaneId
            )
            manager.tabsByServer[tab.serverId] = [tab]
            manager.selectedTabByServer[tab.serverId] = tab.id
            manager.paneStates[tab.rootPaneId] = TerminalPaneState(
                paneId: tab.rootPaneId,
                tabId: tab.id,
                serverId: tab.serverId
            )
            let emptyPayloadRequestID = manager.requestPaneInput(Data(), toPane: tab.rootPaneId)

            // Then the manager rejects both without creating background input work.
            #expect(missingPaneRequestID == nil)
            #expect(emptyPayloadRequestID == nil)
            #expect(manager.pendingInputRequestIDs.isEmpty)
            #expect(recorder.events.isEmpty)
        }
    }

    @Test
    func paneInputRequestsStayTrackedAndPreserveWriteOrder() async {
        await withCleanTabManager { manager in
            let tab = TerminalTab(serverId: UUID(), title: "Tencent")
            manager.tabsByServer[tab.serverId] = [tab]
            manager.selectedTabByServer[tab.serverId] = tab.id
            manager.paneStates[tab.rootPaneId] = TerminalPaneState(
                paneId: tab.rootPaneId,
                tabId: tab.id,
                serverId: tab.serverId
            )

            let recorder = TerminalInputRecorder()
            let gate = TerminalInputGate()
            manager.setInputOperationForTesting { data, entityId in
                let payload = String(decoding: data, as: UTF8.self)
                recorder.recordSync("start-\(entityId)-\(payload)")
                if payload == "x" {
                    await gate.wait()
                }
                recorder.recordSync("end-\(payload)")
            }

            // When two rapid write callbacks send input to the same pane.
            let firstRequestID = try! #require(
                manager.requestPaneInput(Data("x".utf8), toPane: tab.rootPaneId)
            )
            await recorder.waitForCount(1)
            let secondRequestID = try! #require(
                manager.requestPaneInput(Data("y".utf8), toPane: tab.rootPaneId)
            )

            // Then both requests are tracked while the first write is blocked.
            #expect(manager.pendingInputRequestIDs == [firstRequestID, secondRequestID])
            #expect(recorder.events == ["start-pane(\(tab.rootPaneId))-x"])

            await gate.open()
            await manager.waitForInputRequest(firstRequestID)
            await manager.waitForInputRequest(secondRequestID)

            // And the application manager preserves terminal write ordering.
            #expect(
                recorder.events == [
                    "start-pane(\(tab.rootPaneId))-x",
                    "end-x",
                    "start-pane(\(tab.rootPaneId))-y",
                    "end-y"
                ],
                "Rapid pane input must be serialized by the manager instead of racing UI-owned tasks."
            )
            #expect(manager.pendingInputRequestIDs.isEmpty)
        }
    }

    @Test
    func paneInputQueuedAfterPaneRemovalIsDroppedBeforeSending() async {
        await withCleanTabManager { manager in
            let tab = TerminalTab(serverId: UUID(), title: "Tencent")
            manager.tabsByServer[tab.serverId] = [tab]
            manager.selectedTabByServer[tab.serverId] = tab.id
            manager.paneStates[tab.rootPaneId] = TerminalPaneState(
                paneId: tab.rootPaneId,
                tabId: tab.id,
                serverId: tab.serverId
            )

            let recorder = TerminalInputRecorder()
            let gate = TerminalInputGate()
            manager.setInputOperationForTesting { data, _ in
                let payload = String(decoding: data, as: UTF8.self)
                recorder.recordSync("start-\(payload)")
                if payload == "first" {
                    await gate.wait()
                }
                recorder.recordSync("end-\(payload)")
            }

            // Given one input is running and another is queued behind it.
            let firstRequestID = try! #require(
                manager.requestPaneInput(Data("first".utf8), toPane: tab.rootPaneId)
            )
            await recorder.waitForCount(1)
            let secondRequestID = try! #require(
                manager.requestPaneInput(Data("second".utf8), toPane: tab.rootPaneId)
            )

            // When the pane disappears before the queued input can run.
            manager.paneStates.removeValue(forKey: tab.rootPaneId)
            await gate.open()
            await manager.waitForInputRequest(firstRequestID)
            await manager.waitForInputRequest(secondRequestID)

            // Then the queued input is dropped by the manager recheck.
            #expect(recorder.events == ["start-first", "end-first"])
            #expect(manager.pendingInputRequestIDs.isEmpty)
        }
    }

    @Test
    func paneInputRequestsAreClearedWhenPaneCloses() async {
        await withCleanTabManager { manager in
            let tab = TerminalTab(serverId: UUID(), title: "Tencent")
            manager.tabsByServer[tab.serverId] = [tab]
            manager.selectedTabByServer[tab.serverId] = tab.id
            manager.paneStates[tab.rootPaneId] = TerminalPaneState(
                paneId: tab.rootPaneId,
                tabId: tab.id,
                serverId: tab.serverId
            )

            let recorder = TerminalInputRecorder()
            let gate = TerminalInputGate()
            manager.setInputOperationForTesting { data, _ in
                let payload = String(decoding: data, as: UTF8.self)
                recorder.recordSync("start-\(payload)")
                if payload == "first" {
                    await gate.wait()
                }
                recorder.recordSync("end-\(payload)")
            }

            // Given one input is running and another is queued behind it.
            let firstRequestID = try! #require(
                manager.requestPaneInput(Data("first".utf8), toPane: tab.rootPaneId)
            )
            await recorder.waitForCount(1)
            let secondRequestID = try! #require(
                manager.requestPaneInput(Data("second".utf8), toPane: tab.rootPaneId)
            )

            // When the real pane close path completes.
            await manager.closePaneAndWait(tab: tab, paneId: tab.rootPaneId)

            // Then close owns cancellation/cleanup for pending input requests.
            #expect(
                manager.pendingInputRequestIDs.isEmpty,
                "Closing a pane must clear manager-owned input request bookkeeping."
            )

            await gate.open()
            await manager.waitForInputRequest(firstRequestID)
            await manager.waitForInputRequest(secondRequestID)
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
private final class TerminalInputRecorder {
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

private actor TerminalInputGate {
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
