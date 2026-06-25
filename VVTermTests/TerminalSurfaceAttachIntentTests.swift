import Foundation
import Testing
@testable import VVTerm

// Test Context:
// These tests protect terminal surface attach/start policy for root sessions
// and split panes. SwiftUI representables may report value context such as
// scene activity and hold the concrete terminal surface, but shell-state
// checks, reconnect-reset consumption, duplicate-start rejection, and runtime
// attach scheduling must be owned by TerminalSessions application managers.
// Fakes here use DEBUG attach-operation seams and do not construct
// GhosttyTerminalView or open network connections. Update these tests only if
// terminal surface attach/start policy intentionally moves to another non-UI
// owner with equivalent tracking and ordering guarantees.
@Suite(.serialized)
@MainActor
struct TerminalSurfaceAttachIntentTests {
    @Test
    func rootSurfaceAttachRejectsInactiveAndSuspendingContextWithoutConsumingReset() async {
        await withCleanConnectionManager { manager in
            let server = makeServer()
            let session = ConnectionSession(
                serverId: server.id,
                title: "Tencent",
                connectionState: .connecting
            )
            manager.sessions = [session]
            manager.markTerminalForReconnectReset(for: session.id)

            let recorder = SurfaceAttachRecorder()
            manager.setSurfaceAttachOperationForTesting { entityId in
                recorder.record("attach-\(entityId)")
            }

            // Given the app is inactive and background suspension is also in progress.
            manager.setBackgroundSuspendInProgressForTesting(true)
            let inactiveContext = TerminalSurfaceAttachContext(
                isAppActive: false,
                isViewActive: true,
                autoReconnectEnabled: true
            )

            // When SwiftUI reports a ready surface.
            let requestID = manager.requestSurfaceAttachForTesting(
                sessionId: session.id,
                context: inactiveContext,
                resetTerminal: { recorder.recordSync("reset") }
            )

            // Then no attach request starts and reconnect reset remains pending.
            #expect(requestID == nil)
            #expect(manager.pendingSurfaceAttachRequestIDs.isEmpty)
            #expect(recorder.events.isEmpty)
            #expect(
                manager.consumeTerminalReconnectReset(for: session.id),
                "Rejected surface attach must not consume reconnect reset."
            )
        }
    }

    @Test
    func rootSurfaceAttachConsumesResetOnlyWhenAttachRuns() async {
        await withCleanConnectionManager { manager in
            let server = makeServer()
            let session = ConnectionSession(
                serverId: server.id,
                title: "Tencent",
                connectionState: .connecting
            )
            manager.sessions = [session]
            manager.markTerminalForReconnectReset(for: session.id)

            let recorder = SurfaceAttachRecorder()
            let gate = SurfaceAttachGate()
            manager.setSurfaceAttachOperationForTesting { entityId in
                recorder.record("attach-start-\(entityId)")
                await gate.wait()
                recorder.record("attach-end")
            }

            // When the app-owned manager accepts an active surface attach.
            let requestID = manager.requestSurfaceAttachForTesting(
                sessionId: session.id,
                context: .active,
                resetTerminal: { recorder.recordSync("reset") }
            )

            // Then the request is tracked until the attach operation finishes,
            // and reconnect reset is consumed only for the accepted attach.
            let unwrappedRequestID = try! #require(requestID)
            await recorder.waitForCount(2)
            let duplicateRequestID = manager.requestSurfaceAttachForTesting(
                sessionId: session.id,
                context: .active
            )
            let inactiveDuplicateRequestID = manager.requestSurfaceAttachForTesting(
                sessionId: session.id,
                context: TerminalSurfaceAttachContext(
                    isAppActive: false,
                    isViewActive: true,
                    autoReconnectEnabled: true
                )
            )
            #expect(manager.pendingSurfaceAttachRequestIDs == [unwrappedRequestID])
            #expect(duplicateRequestID == unwrappedRequestID)
            #expect(inactiveDuplicateRequestID == nil)
            #expect(!manager.consumeTerminalReconnectReset(for: session.id))
            #expect(recorder.events == ["reset", "attach-start-session(\(session.id))"])

            await gate.open()
            await manager.waitForSurfaceAttachRequest(unwrappedRequestID)

            #expect(recorder.events == ["reset", "attach-start-session(\(session.id))", "attach-end"])
            #expect(manager.pendingSurfaceAttachRequestIDs.isEmpty)
        }
    }

    @Test
    func rootSurfaceAttachRejectsExistingShellAndShellStartInFlight() async {
        await withCleanConnectionManager { manager in
            let server = makeServer()
            let session = ConnectionSession(
                serverId: server.id,
                title: "Tencent",
                connectionState: .connected
            )
            manager.sessions = [session]

            let recorder = SurfaceAttachRecorder()
            manager.setSurfaceAttachOperationForTesting { entityId in
                recorder.record("attach-\(entityId)")
            }

            // Given a shell start is already in flight for this session.
            _ = manager.beginShellStartForTesting(
                sessionId: session.id,
                serverId: server.id,
                client: SSHClient()
            )

            // Then a second surface attach request is rejected before it can
            // race another runtime start.
            #expect(
                manager.requestSurfaceAttachForTesting(sessionId: session.id, context: .active) == nil
            )
            #expect(recorder.events.isEmpty)

            manager.closeShellRegistrationForTesting(sessionId: session.id)
            manager.registerSSHClient(
                SSHClient(),
                shellId: UUID(),
                for: session.id,
                serverId: server.id,
                skipTmuxLifecycle: true
            )

            #expect(
                manager.requestSurfaceAttachForTesting(sessionId: session.id, context: .active) == nil
            )
            #expect(recorder.events.isEmpty)
        }
    }

    @Test
    func rootDisconnectedSurfaceAttachRequiresActiveViewAndAutoReconnect() async {
        await withCleanConnectionManager { manager in
            let server = makeServer()
            let session = ConnectionSession(
                serverId: server.id,
                title: "Tencent",
                connectionState: .disconnected
            )
            manager.sessions = [session]

            let recorder = SurfaceAttachRecorder()
            manager.setSurfaceAttachOperationForTesting { entityId in
                recorder.record("attach-\(entityId)")
            }

            // Given the session is disconnected.
            #expect(
                manager.requestSurfaceAttachForTesting(
                    sessionId: session.id,
                    context: TerminalSurfaceAttachContext(
                        isAppActive: true,
                        isViewActive: false,
                        autoReconnectEnabled: true
                    )
                ) == nil
            )
            #expect(
                manager.requestSurfaceAttachForTesting(
                    sessionId: session.id,
                    context: TerminalSurfaceAttachContext(
                        isAppActive: true,
                        isViewActive: true,
                        autoReconnectEnabled: false
                    )
                ) == nil
            )

            // When the view is active and auto-reconnect is enabled.
            let requestID = try! #require(
                manager.requestSurfaceAttachForTesting(sessionId: session.id, context: .active)
            )
            await manager.waitForSurfaceAttachRequest(requestID)

            // Then the manager owns the accepted attach operation.
            #expect(recorder.events == ["attach-session(\(session.id))"])
        }
    }

    @Test
    func paneSurfaceAttachTracksAcceptedRequestAndRejectsDuplicateShellStart() async {
        await withCleanTabManager { manager in
            let server = makeServer()
            let tab = TerminalTab(serverId: server.id, title: "Tencent")
            manager.tabsByServer[server.id] = [tab]
            manager.selectedTabByServer[server.id] = tab.id
            manager.paneStates[tab.rootPaneId] = TerminalPaneState(
                paneId: tab.rootPaneId,
                tabId: tab.id,
                serverId: server.id
            )

            let recorder = SurfaceAttachRecorder()
            let gate = SurfaceAttachGate()
            manager.setSurfaceAttachOperationForTesting { entityId in
                recorder.record("attach-start-\(entityId)")
                await gate.wait()
                recorder.record("attach-end")
            }

            // When the pane surface attach request is accepted.
            let requestID = try! #require(
                manager.requestSurfaceAttachForTesting(
                    paneId: tab.rootPaneId,
                    context: .active
                )
            )
            await recorder.waitForCount(1)

            // Then duplicate attach intent coalesces with the tracked request.
            let duplicateRequestID = manager.requestSurfaceAttachForTesting(
                paneId: tab.rootPaneId,
                context: .active
            )
            let inactiveDuplicateRequestID = manager.requestSurfaceAttachForTesting(
                paneId: tab.rootPaneId,
                context: TerminalSurfaceAttachContext(
                    isAppActive: false,
                    isViewActive: true,
                    autoReconnectEnabled: true
                )
            )
            #expect(duplicateRequestID == requestID)
            #expect(inactiveDuplicateRequestID == nil)
            #expect(manager.pendingSurfaceAttachRequestIDs == [requestID])

            await gate.open()
            await manager.waitForSurfaceAttachRequest(requestID)

            #expect(recorder.events == ["attach-start-pane(\(tab.rootPaneId))", "attach-end"])
            #expect(manager.pendingSurfaceAttachRequestIDs.isEmpty)

            _ = manager.beginShellStartForTesting(
                paneId: tab.rootPaneId,
                serverId: server.id,
                client: SSHClient()
            )
            #expect(
                manager.requestSurfaceAttachForTesting(paneId: tab.rootPaneId, context: .active) == nil
            )
        }
    }

    private func makeServer(
        id: UUID = UUID(),
        workspaceId: UUID = UUID(),
        name: String = "Tencent"
    ) -> Server {
        Server(
            id: id,
            workspaceId: workspaceId,
            name: name,
            host: "ssh.example.com",
            username: "root",
            connectionMode: .standard
        )
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
private final class SurfaceAttachRecorder {
    private(set) var events: [String] = []

    func record(_ event: String) {
        events.append(event)
    }

    func recordSync(_ event: String) {
        events.append(event)
    }

    func waitForCount(_ count: Int) async {
        while events.count < count {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}

private actor SurfaceAttachGate {
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
