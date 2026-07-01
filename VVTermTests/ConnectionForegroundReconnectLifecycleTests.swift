import Foundation
import Testing
@testable import VVTerm

// Test Context:
// These integration tests protect foreground and auto-reconnect request
// lifecycle ordering for root terminal sessions. They use real
// ConnectionSessionManager state with injected blocking reconnect operations,
// so failures usually mean runtime liveness checks, request coalescing,
// cancellation, or callback delivery moved across the application/UI boundary.
// Update only when that foreground reconnect contract intentionally changes.

@Suite(.serialized)
@MainActor
struct ConnectionForegroundReconnectLifecycleTests {
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

    @Test
    func connectionManagerAutoReconnectIntentUsesManagerRuntimeState() async {
        await withCleanConnectionManager { manager in
            let server = makeServer()
            let session = ConnectionSession(
                serverId: server.id,
                title: server.name,
                connectionState: .disconnected
            )
            manager.sessions = [session]

            // Given SwiftUI sends scene/setting intent only and the application
            // layer owns the session snapshot plus runtime liveness lookup.
            #expect(
                manager.shouldAutoReconnectSession(
                    session.id,
                    isSceneActive: true,
                    autoReconnectEnabled: true,
                    reconnectInFlight: false
                ),
                "Disconnected sessions without live runtime should be eligible for app-layer auto reconnect."
            )

            // When the runtime registry says the session is already opening,
            // even if the UI display snapshot later appears disconnected.
            manager.updateSessionState(session.id, to: .connecting)
            manager.sessions[0].connectionState = .disconnected

            // Then the application-layer intent must suppress a duplicate
            // reconnect without asking SwiftUI to combine registry state.
            #expect(
                !manager.shouldAutoReconnectSession(
                    session.id,
                    isSceneActive: true,
                    autoReconnectEnabled: true,
                    reconnectInFlight: false
                ),
                "Auto reconnect intent should use manager-owned runtime liveness, not stale SwiftUI session snapshots."
            )
        }
    }

    @Test
    func connectionManagerForegroundReconnectActionUsesSelectedRuntimeState() async {
        await withCleanConnectionManager { manager in
            let server = makeServer()
            let session = ConnectionSession(
                serverId: server.id,
                title: server.name,
                connectionState: .disconnected
            )
            manager.sessions = [session]
            manager.selectedSessionId = session.id

            // Given the iOS shell sends foreground/selection intent to the
            // application layer instead of deriving runtime liveness in SwiftUI.
            let reconnectAction = manager.foregroundReconnectActionForSelectedSession(
                selectedViewId: "terminal",
                terminalViewId: "terminal",
                refreshTerminal: true,
                autoReconnectEnabled: true
            )

            // Then the manager returns the UI side effects while owning the
            // reconnect decision and selected-session lookup.
            #expect(reconnectAction?.sessionId == session.id)
            #expect(reconnectAction?.shouldRefreshTerminal == true)
            #expect(reconnectAction?.shouldReconnect == true)
            #expect(reconnectAction?.shouldForceTerminalVisible == true)

            // When a live runtime exists but the UI display snapshot is stale.
            manager.updateSessionState(session.id, to: .connected)
            manager.sessions[0].connectionState = .disconnected

            // Then foreground intent must not create a duplicate reconnect.
            let liveAction = manager.foregroundReconnectActionForSelectedSession(
                selectedViewId: "terminal",
                terminalViewId: "terminal",
                refreshTerminal: true,
                autoReconnectEnabled: true
            )
            #expect(liveAction?.shouldReconnect == false)
            #expect(liveAction?.shouldForceTerminalVisible == false)
        }
    }

    @Test
    func connectionManagerForegroundReconnectIntentExecutesReconnectInApplicationLayer() async {
        await withCleanConnectionManager { manager in
            let server = makeServer()
            let session = ConnectionSession(
                serverId: server.id,
                title: server.name,
                connectionState: .disconnected
            )
            manager.sessions = [session]
            manager.selectedSessionId = session.id

            await withServerList([server]) {
                // Given iOS sends foreground intent to the application layer.
                let action = await manager.handleForegroundReconnectForSelectedSession(
                    selectedViewId: "terminal",
                    terminalViewId: "terminal",
                    refreshTerminal: true,
                    autoReconnectEnabled: true
                )

                // Then the manager returns UI render instructions and performs
                // reconnect execution itself.
                #expect(action?.sessionId == session.id)
                #expect(action?.shouldReconnect == true)
                #expect(manager.sessionState(for: session.id) == .reconnecting(attempt: 1))
            }
        }
    }

    @Test
    func foregroundReconnectRequestTracksReconnectUntilCompletion() async {
        await withCleanConnectionManager { manager in
            let server = makeServer()
            let session = ConnectionSession(
                serverId: server.id,
                title: server.name,
                connectionState: .disconnected
            )
            manager.sessions = [session]
            manager.selectedSessionId = session.id
            let reconnectGate = ForegroundReconnectTaskGate()
            var reconnectCalls: [UUID] = []
            var actions: [TerminalForegroundReconnectAction] = []

            manager.setForegroundReconnectOperationForTesting { requestSession in
                reconnectCalls.append(requestSession.id)
                await reconnectGate.waitForRelease()
                return true
            }

            // Given iOS foreground/scene/selection intent asks the application
            // owner to reconnect the selected disconnected session.
            guard let requestID = manager.requestForegroundReconnectForSelectedSession(
                selectedViewId: "terminal",
                terminalViewId: "terminal",
                refreshTerminal: true,
                autoReconnectEnabled: true,
                onAction: { actions.append($0) }
            ) else {
                Issue.record("Foreground reconnect intent should produce a tracked request for the selected session.")
                return
            }

            // Then the request remains visible while reconnect work is blocked.
            #expect(
                manager.pendingForegroundReconnectRequestIDs.contains(requestID),
                "Foreground reconnect request should stay pending while reconnect work is in flight."
            )
            #expect(actions.isEmpty)

            await reconnectGate.release()
            await manager.waitForForegroundReconnectRequest(requestID)

            #expect(reconnectCalls == [session.id])
            #expect(actions.count == 1)
            #expect(actions.first?.sessionId == session.id)
            #expect(actions.first?.shouldRefreshTerminal == true)
            #expect(actions.first?.shouldReconnect == true)
            #expect(actions.first?.shouldForceTerminalVisible == true)
            #expect(!manager.pendingForegroundReconnectRequestIDs.contains(requestID))
        }
    }

    @Test
    func duplicateForegroundReconnectRequestsCoalesceUntilCompletion() async {
        await withCleanConnectionManager { manager in
            let server = makeServer()
            let session = ConnectionSession(
                serverId: server.id,
                title: server.name,
                connectionState: .disconnected
            )
            manager.sessions = [session]
            manager.selectedSessionId = session.id
            let reconnectGate = ForegroundReconnectTaskGate()
            var reconnectCalls: [UUID] = []
            var callbacks: [String] = []

            manager.setForegroundReconnectOperationForTesting { requestSession in
                reconnectCalls.append(requestSession.id)
                await reconnectGate.waitForRelease()
                return true
            }

            // Given foreground reconnect intent is repeated before the first
            // reconnect/runtime-liveness request finishes.
            let firstID = manager.requestForegroundReconnectForSelectedSession(
                selectedViewId: "terminal",
                terminalViewId: "terminal",
                refreshTerminal: true,
                autoReconnectEnabled: true,
                onAction: { _ in callbacks.append("first") }
            )
            let secondID = manager.requestForegroundReconnectForSelectedSession(
                selectedViewId: "terminal",
                terminalViewId: "terminal",
                refreshTerminal: true,
                autoReconnectEnabled: true,
                onAction: { _ in callbacks.append("second") }
            )

            guard let firstID else {
                Issue.record("First foreground reconnect intent should produce a request.")
                return
            }

            // Then duplicate same-session intent joins the existing manager
            // request instead of launching duplicate reconnect work.
            #expect(firstID == secondID)
            #expect(manager.pendingForegroundReconnectRequestIDs == [firstID])

            await reconnectGate.release()
            await manager.waitForForegroundReconnectRequest(firstID)

            #expect(reconnectCalls == [session.id])
            #expect(callbacks == ["first", "second"])
            #expect(!manager.pendingForegroundReconnectRequestIDs.contains(firstID))
        }
    }

    @Test
    func duplicateForegroundReconnectRequestsPreserveEachCallbackAction() async {
        await withCleanConnectionManager { manager in
            let server = makeServer()
            let session = ConnectionSession(
                serverId: server.id,
                title: server.name,
                connectionState: .disconnected
            )
            manager.sessions = [session]
            manager.selectedSessionId = session.id
            let reconnectGate = ForegroundReconnectTaskGate()
            var callbackActions: [TerminalForegroundReconnectAction] = []

            manager.setForegroundReconnectOperationForTesting { _ in
                await reconnectGate.waitForRelease()
                return true
            }

            // Given duplicate foreground intents ask for different presentation
            // refresh behavior while sharing the same reconnect operation.
            let firstID = manager.requestForegroundReconnectForSelectedSession(
                selectedViewId: "terminal",
                terminalViewId: "terminal",
                refreshTerminal: false,
                autoReconnectEnabled: true,
                onAction: { callbackActions.append($0) }
            )
            let secondID = manager.requestForegroundReconnectForSelectedSession(
                selectedViewId: "terminal",
                terminalViewId: "terminal",
                refreshTerminal: true,
                autoReconnectEnabled: true,
                onAction: { callbackActions.append($0) }
            )

            guard let firstID else {
                Issue.record("First foreground reconnect intent should produce a request.")
                return
            }

            // Then the reconnect work is coalesced but each callback keeps the
            // presentation action computed for the intent that registered it.
            #expect(firstID == secondID)

            await reconnectGate.release()
            await manager.waitForForegroundReconnectRequest(firstID)

            #expect(callbackActions.map(\.shouldRefreshTerminal) == [false, true])
            #expect(callbackActions.map(\.shouldReconnect) == [true, true])
            #expect(callbackActions.map(\.shouldForceTerminalVisible) == [true, true])
        }
    }

    @Test
    func foregroundReconnectCompletionCanStartFreshReconnectRequest() async {
        await withCleanConnectionManager { manager in
            let server = makeServer()
            let session = ConnectionSession(
                serverId: server.id,
                title: server.name,
                connectionState: .disconnected
            )
            manager.sessions = [session]
            manager.selectedSessionId = session.id
            let reconnectGate = ForegroundReconnectTaskGate()
            var callbackTriggeredRequestID: UUID?

            manager.setForegroundReconnectOperationForTesting { _ in
                await reconnectGate.waitForRelease()
                return true
            }

            // Given foreground reconnect completion immediately sends another
            // selected-session reconnect intent to the application owner.
            guard let firstRequestID = manager.requestForegroundReconnectForSelectedSession(
                selectedViewId: "terminal",
                terminalViewId: "terminal",
                refreshTerminal: true,
                autoReconnectEnabled: true,
                onAction: { _ in
                    callbackTriggeredRequestID = manager.requestForegroundReconnectForSelectedSession(
                        selectedViewId: "terminal",
                        terminalViewId: "terminal",
                        refreshTerminal: true,
                        autoReconnectEnabled: true
                    )
                }
            ) else {
                Issue.record("Foreground reconnect intent should produce a tracked request.")
                return
            }
            await reconnectGate.waitForCallCount(1)

            // When the first foreground reconnect finishes.
            await reconnectGate.release()
            await manager.waitForForegroundReconnectRequest(firstRequestID)
            for _ in 0..<50 where await reconnectGate.callCount < 2 {
                try? await Task.sleep(for: .milliseconds(10))
            }

            // Then the callback-triggered intent owns a new reconnect lifecycle
            // instead of joining the completed request that is about to clear.
            #expect(callbackTriggeredRequestID != nil)
            #expect(callbackTriggeredRequestID != firstRequestID)
            #expect(await reconnectGate.callCount == 2)
        }
    }

    @Test
    func closeSessionCancelsPendingForegroundReconnectRequest() async {
        await withCleanConnectionManager { manager in
            let server = makeServer()
            let session = ConnectionSession(
                serverId: server.id,
                title: server.name,
                connectionState: .disconnected
            )
            manager.sessions = [session]
            manager.selectedSessionId = session.id
            let reconnectGate = ForegroundReconnectTaskGate()
            let reconnectStartedProbe = ForegroundReconnectWaitProbe()
            var actions: [TerminalForegroundReconnectAction] = []

            manager.setForegroundReconnectOperationForTesting { _ in
                await reconnectStartedProbe.markReturned()
                await reconnectGate.waitForRelease()
                return true
            }

            // Given foreground reconnect work is pending when the owning
            // session closes.
            guard let requestID = manager.requestForegroundReconnectForSelectedSession(
                selectedViewId: "terminal",
                terminalViewId: "terminal",
                refreshTerminal: true,
                autoReconnectEnabled: true,
                onAction: { actions.append($0) }
            ) else {
                Issue.record("Foreground reconnect intent should produce a request before session close.")
                return
            }
            #expect(manager.pendingForegroundReconnectRequestIDs.contains(requestID))
            while await !reconnectStartedProbe.didReturn {
                try? await Task.sleep(for: .milliseconds(5))
            }

            await manager.closeSessionAndWait(session)
            let waitProbe = ForegroundReconnectWaitProbe()
            let waitTask = Task {
                await manager.waitForForegroundReconnectRequest(requestID)
                await waitProbe.markReturned()
            }
            try? await Task.sleep(for: .milliseconds(20))

            // Then close clears visible pending state immediately but keeps the
            // request awaitable until the blocked reconnect operation exits.
            #expect(
                !manager.pendingForegroundReconnectRequestIDs.contains(requestID),
                "Closing a session should cancel visible foreground reconnect intent for that session."
            )
            #expect(
                await !waitProbe.didReturn,
                "Foreground reconnect wait hook must remain tracked until blocked reconnect work exits."
            )

            await reconnectGate.release()
            await waitTask.value

            #expect(await waitProbe.didReturn)
            #expect(actions.isEmpty)
        }
    }
}

private actor ForegroundReconnectTaskGate {
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var callContinuations: [CheckedContinuation<Void, Never>] = []
    private var isReleased = false
    private(set) var callCount = 0

    func waitForRelease() async {
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

private actor ForegroundReconnectWaitProbe {
    private(set) var didReturn = false

    func markReturned() {
        didReturn = true
    }
}
