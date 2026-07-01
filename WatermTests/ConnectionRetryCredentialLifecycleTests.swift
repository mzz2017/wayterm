import Foundation
import Testing
@testable import Waterm

// Test Context:
// These integration tests protect retry, credential-load, and host-retrust
// request lifecycle ordering. They use real manager singletons with injected
// blocking providers/operations, so failures usually mean request coalescing,
// cancellation, runtime liveness revalidation, or application-owned credential
// boundaries changed. Update only when that request contract intentionally
// changes.

@Suite(.serialized)
@MainActor
struct ConnectionRetryCredentialLifecycleTests {
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

    private func makeCredentials(serverId: UUID) -> ServerCredentials {
        ServerCredentials(
            serverId: serverId,
            password: nil,
            privateKey: nil,
            publicKey: nil,
            passphrase: nil,
            cloudflareClientID: nil,
            cloudflareClientSecret: nil
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
    func connectionManagerRetryLoadsCredentialsAndGatesDuplicateRequests() async {
        await withCleanConnectionManager { manager in
            let server = makeServer()
            let session = ConnectionSession(
                serverId: server.id,
                title: server.name,
                connectionState: .disconnected
            )
            let credentialGate = RetryCredentialProviderGate(credentials: makeCredentials(serverId: server.id))
            manager.sessions = [session]
            manager.setCredentialsProviderForTesting { _ in
                await credentialGate.load()
            }

            await withServerList([server]) {
                // Given SwiftUI sends retry intent while credential loading is
                // still in progress inside the application layer.
                let firstRetry = Task {
                    await manager.retrySessionConnection(session: session, server: server)
                }
                try? await Task.sleep(for: .milliseconds(20))

                // When another retry intent arrives before credential loading
                // completes.
                let duplicateResult = await manager.retrySessionConnection(
                    session: session,
                    server: server
                )

                // Then the manager-owned retry gate rejects the duplicate
                // without asking SwiftUI to track reconnectInFlight.
                #expect(duplicateResult.isSkipped)

                await credentialGate.release()
                let result = await firstRetry.value
                #expect(
                    result.credentials?.serverId == server.id,
                    "A successful retry should return loaded credentials for the UI wrapper to render."
                )
                #expect(
                    await credentialGate.loadCount == 1,
                    "Duplicate retry intent must not load credentials a second time."
                )
                #expect(manager.sessionState(for: session.id) == .reconnecting(attempt: 1))
            }
        }
    }

    @Test
    func connectionManagerRetryRequestCoalescesDuplicateCallersUntilOperationCompletes() async {
        await withCleanConnectionManager { manager in
            let server = makeServer()
            let session = ConnectionSession(
                serverId: server.id,
                title: server.name,
                connectionState: .disconnected
            )
            let gate = RetryOperationGate()
            let credentials = makeCredentials(serverId: server.id)
            manager.sessions = [session]
            manager.setSessionRetryOperationForTesting { requestSession, requestServer in
                #expect(
                    requestSession.id == session.id,
                    "The tracked retry request should target the requested session."
                )
                #expect(
                    requestServer?.id == server.id,
                    "The tracked retry request should use the server passed by SwiftUI intent."
                )
                await gate.run()
                return .started(credentials)
            }
            var firstResult: TerminalReconnectRequestResult?
            var secondResult: TerminalReconnectRequestResult?

            // Given SwiftUI sends retry intent and the application layer owns
            // the blocking credential/reconnect operation.
            let firstRequestID = manager.requestSessionRetry(
                session: session,
                server: server,
                onCompleted: { firstResult = $0 }
            )

            // When the same session asks again before retry completion.
            let secondRequestID = manager.requestSessionRetry(
                session: session,
                server: server,
                onCompleted: { secondResult = $0 }
            )
            await gate.waitForCallCount(1)

            // Then the manager coalesces duplicate intent and keeps the
            // request awaitable until the retry operation finishes.
            #expect(secondRequestID == firstRequestID)
            #expect(
                manager.pendingSessionRetryRequestIDs == [firstRequestID],
                "Session retry must remain pending while manager-owned work is blocked."
            )
            #expect(firstResult == nil)
            #expect(secondResult == nil)
            #expect(await gate.callCount == 1)

            await gate.release()
            await manager.waitForSessionRetryRequest(firstRequestID)

            #expect(firstResult?.credentials?.serverId == server.id)
            #expect(secondResult?.credentials?.serverId == server.id)
            #expect(
                manager.pendingSessionRetryRequestIDs.isEmpty,
                "Session retry request state should clear after callbacks receive the final result."
            )
        }
    }

    @Test
    func connectionManagerRetryCompletionCanStartFreshRetryRequest() async {
        await withCleanConnectionManager { manager in
            let server = makeServer()
            let session = ConnectionSession(
                serverId: server.id,
                title: server.name,
                connectionState: .disconnected
            )
            let gate = RetryOperationGate()
            let credentials = makeCredentials(serverId: server.id)
            manager.sessions = [session]
            manager.setSessionRetryOperationForTesting { _, _ in
                await gate.run()
                return .started(credentials)
            }
            var callbackTriggeredRequestID: UUID?

            // Given a retry request is completing and its callback immediately
            // asks the application owner to try again.
            let firstRequestID = manager.requestSessionRetry(
                session: session,
                server: server,
                onCompleted: { _ in
                    callbackTriggeredRequestID = manager.requestSessionRetry(
                        session: session,
                        server: server
                    )
                }
            )
            await gate.waitForCallCount(1)

            // When the first retry finishes.
            await gate.release()
            await manager.waitForSessionRetryRequest(firstRequestID)
            for _ in 0..<50 where await gate.callCount < 2 {
                try? await Task.sleep(for: .milliseconds(10))
            }

            // Then the callback-triggered retry owns a new lifecycle instead
            // of being joined to the completed request that is about to clear.
            #expect(callbackTriggeredRequestID != nil)
            #expect(callbackTriggeredRequestID != firstRequestID)
            #expect(await gate.callCount == 2)
        }
    }

    @Test
    func connectionManagerRetrySkipsIfRuntimeBecomesLiveWhileLoadingCredentials() async {
        await withCleanConnectionManager { manager in
            let server = makeServer()
            let session = ConnectionSession(
                serverId: server.id,
                title: server.name,
                connectionState: .disconnected
            )
            let credentialGate = RetryCredentialProviderGate(credentials: makeCredentials(serverId: server.id))
            manager.sessions = [session]
            manager.setCredentialsProviderForTesting { _ in
                await credentialGate.load()
            }

            await withServerList([server]) {
                // Given retry intent has started credential loading.
                let retryTask = Task {
                    await manager.retrySessionConnection(session: session, server: server)
                }
                try? await Task.sleep(for: .milliseconds(20))

                // When the runtime becomes live before credential loading
                // returns to the manager.
                manager.updateSessionState(session.id, to: .connected)
                manager.sessions[0].connectionState = .disconnected
                await credentialGate.release()
                let result = await retryTask.value

                // Then the retry intent is skipped and the UI should not
                // rebuild a wrapper for a stale reconnect.
                #expect(
                    result.isSkipped,
                    "Retry must revalidate runtime liveness after awaited credential loading."
                )
            }
        }
    }

    @Test
    func connectionManagerHostRetrustRequestCoalescesDuplicateCallersUntilOperationCompletes() async {
        await withCleanConnectionManager { manager in
            let server = makeServer()
            let session = ConnectionSession(
                serverId: server.id,
                title: server.name,
                connectionState: .failed("Host key verification failed")
            )
            let gate = RetryOperationGate()
            manager.sessions = [session]
            manager.setSessionHostRetrustOperationForTesting { requestSession, requestServer in
                #expect(
                    requestSession.id == session.id,
                    "The tracked host-retrust request should target the requested session."
                )
                #expect(
                    requestServer.id == server.id,
                    "The tracked host-retrust request should use the server passed by SwiftUI intent."
                )
                await gate.run()
                return true
            }
            var firstResult: Bool?
            var secondResult: Bool?

            // Given terminal UI sends host-retrust intent and the application
            // layer owns the blocking trust-store mutation plus reconnect work.
            let firstRequestID = manager.requestSessionHostRetrust(
                session: session,
                server: server,
                onCompleted: { firstResult = $0 }
            )

            // When the same session asks again before retrust completion.
            let secondRequestID = manager.requestSessionHostRetrust(
                session: session,
                server: server,
                onCompleted: { secondResult = $0 }
            )
            await gate.waitForCallCount(1)

            // Then duplicate callers share one awaitable manager-owned request.
            #expect(secondRequestID == firstRequestID)
            #expect(
                manager.pendingSessionHostRetrustRequestIDs == [firstRequestID],
                "Session host retrust must remain pending while manager-owned work is blocked."
            )
            #expect(firstResult == nil)
            #expect(secondResult == nil)
            #expect(await gate.callCount == 1)

            await gate.release()
            await manager.waitForSessionHostRetrustRequest(firstRequestID)

            #expect(firstResult == true)
            #expect(secondResult == true)
            #expect(
                manager.pendingSessionHostRetrustRequestIDs.isEmpty,
                "Session host-retrust request state should clear after callbacks receive the final result."
            )
        }
    }

    @Test
    func connectionManagerHostRetrustCompletionCanStartFreshRetrustRequest() async {
        await withCleanConnectionManager { manager in
            let server = makeServer()
            let session = ConnectionSession(
                serverId: server.id,
                title: server.name,
                connectionState: .failed("Host key verification failed")
            )
            let gate = RetryOperationGate()
            manager.sessions = [session]
            manager.setSessionHostRetrustOperationForTesting { _, _ in
                await gate.run()
                return true
            }
            var callbackTriggeredRequestID: UUID?

            // Given host-retrust completion immediately asks the application
            // owner to retry trust and reconnect again.
            let firstRequestID = manager.requestSessionHostRetrust(
                session: session,
                server: server,
                onCompleted: { _ in
                    callbackTriggeredRequestID = manager.requestSessionHostRetrust(
                        session: session,
                        server: server
                    )
                }
            )
            await gate.waitForCallCount(1)

            // When the first retrust request finishes.
            await gate.release()
            await manager.waitForSessionHostRetrustRequest(firstRequestID)
            for _ in 0..<50 where await gate.callCount < 2 {
                try? await Task.sleep(for: .milliseconds(10))
            }

            // Then the callback-triggered retrust intent starts a fresh owner
            // request instead of joining the completing request.
            #expect(callbackTriggeredRequestID != nil)
            #expect(callbackTriggeredRequestID != firstRequestID)
            #expect(await gate.callCount == 2)
        }
    }

    @Test
    func connectionManagerLoadsCredentialsThroughApplicationBoundary() async {
        await withCleanConnectionManager { manager in
            let server = makeServer()
            manager.setCredentialsProviderForTesting { server in
                makeCredentials(serverId: server.id)
            }

            // Given SwiftUI needs credentials for rendering the terminal
            // wrapper but must not read Keychain directly.
            let result = await manager.loadCredentials(for: server)

            // Then the application layer performs credential loading and
            // returns only the renderable value or user-facing error.
            #expect(
                result.credentials?.serverId == server.id,
                "TerminalContainerView should obtain wrapper credentials through ConnectionSessionManager."
            )
        }
    }

    @Test
    func connectionManagerCredentialLoadRequestCoalescesDuplicateCallersUntilProviderCompletes() async {
        await withCleanConnectionManager { manager in
            let server = makeServer()
            let session = ConnectionSession(serverId: server.id, title: server.name)
            let credentialGate = RetryCredentialProviderGate(credentials: makeCredentials(serverId: server.id))
            manager.sessions = [session]
            manager.setCredentialsProviderForTesting { _ in
                await credentialGate.load()
            }
            var firstResult: TerminalCredentialLoadResult?
            var secondResult: TerminalCredentialLoadResult?

            // Given root terminal UI sends credential-load intent and the
            // Keychain-backed provider is still blocked.
            let firstRequestID = manager.requestSessionCredentialLoad(
                session: session,
                server: server,
                onCompleted: { firstResult = $0 }
            )
            let secondRequestID = manager.requestSessionCredentialLoad(
                session: session,
                server: server,
                onCompleted: { secondResult = $0 }
            )
            await credentialGate.waitForLoadCount(1)

            // Then duplicate intent shares one manager-owned request.
            #expect(secondRequestID == firstRequestID)
            #expect(
                manager.pendingSessionCredentialLoadRequestIDs == [firstRequestID],
                "Session credential load should stay pending while Keychain work is blocked."
            )
            #expect(firstResult == nil)
            #expect(secondResult == nil)
            #expect(await credentialGate.loadCount == 1)

            await credentialGate.release()
            await manager.waitForSessionCredentialLoadRequest(firstRequestID)

            #expect(firstResult?.credentials?.serverId == server.id)
            #expect(secondResult?.credentials?.serverId == server.id)
            #expect(
                manager.pendingSessionCredentialLoadRequestIDs.isEmpty,
                "Session credential-load request state should clear after callbacks receive the final result."
            )
        }
    }

    @Test
    func connectionManagerCredentialLoadCompletionCanStartFreshLoadRequest() async {
        await withCleanConnectionManager { manager in
            let server = makeServer()
            let session = ConnectionSession(serverId: server.id, title: server.name)
            let credentialGate = RetryCredentialProviderGate(credentials: makeCredentials(serverId: server.id))
            manager.sessions = [session]
            manager.setCredentialsProviderForTesting { _ in
                await credentialGate.load()
            }
            var callbackTriggeredRequestID: UUID?

            // Given credential-load completion immediately asks the
            // application owner to load credentials again.
            let firstRequestID = manager.requestSessionCredentialLoad(
                session: session,
                server: server,
                onCompleted: { _ in
                    callbackTriggeredRequestID = manager.requestSessionCredentialLoad(
                        session: session,
                        server: server
                    )
                }
            )
            await credentialGate.waitForLoadCount(1)

            // When the first Keychain-backed load finishes.
            await credentialGate.release()
            await manager.waitForSessionCredentialLoadRequest(firstRequestID)
            for _ in 0..<50 where await credentialGate.loadCount < 2 {
                try? await Task.sleep(for: .milliseconds(10))
            }

            // Then the callback-triggered credential intent starts a fresh
            // owner request instead of joining the completing request.
            #expect(callbackTriggeredRequestID != nil)
            #expect(callbackTriggeredRequestID != firstRequestID)
            #expect(await credentialGate.loadCount == 2)
        }
    }

    @Test
    func connectionManagerCloseSessionCancelsPendingCredentialLoadRequest() async {
        await withCleanConnectionManager { manager in
            let server = makeServer()
            let session = ConnectionSession(serverId: server.id, title: server.name)
            let credentialGate = RetryCredentialProviderGate(credentials: makeCredentials(serverId: server.id))
            manager.sessions = [session]
            manager.setCredentialsProviderForTesting { _ in
                await credentialGate.load()
            }
            var results: [TerminalCredentialLoadResult] = []

            // Given a credential-load request is pending for a session.
            let requestID = manager.requestSessionCredentialLoad(
                session: session,
                server: server,
                onCompleted: { results.append($0) }
            )
            await credentialGate.waitForLoadCount(1)

            // When the owning session closes before the provider returns.
            await manager.closeSessionAndWait(session)
            let waitProbe = RetryWaitProbe()
            let waitTask = Task {
                await manager.waitForSessionCredentialLoadRequest(requestID)
                await waitProbe.markReturned()
            }
            try? await Task.sleep(for: .milliseconds(20))

            // Then request state clears as lifecycle cancellation, not as a
            // user-facing credential failure.
            #expect(manager.pendingSessionCredentialLoadRequestIDs.isEmpty)
            #expect(results.isEmpty)
            #expect(
                await !waitProbe.didReturn,
                "Credential-load wait hook must remain tracked until the blocked provider exits."
            )
            await credentialGate.release()
            await waitTask.value
            #expect(await waitProbe.didReturn)
            try? await Task.sleep(for: .milliseconds(20))
            #expect(
                results.isEmpty,
                "A canceled session credential-load request must not send a later success or failure callback."
            )
        }
    }

}

private actor RetryWaitProbe {
    private(set) var didReturn = false

    func markReturned() {
        didReturn = true
    }
}

private actor RetryCredentialProviderGate {
    private let credentials: ServerCredentials
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var loadCountContinuations: [(Int, CheckedContinuation<Void, Never>)] = []
    private(set) var loadCount = 0

    init(credentials: ServerCredentials) {
        self.credentials = credentials
    }

    func load() async -> ServerCredentials {
        loadCount += 1
        resumeLoadCountContinuations()
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
        return credentials
    }

    func waitForLoadCount(_ expectedCount: Int) async {
        if loadCount >= expectedCount { return }
        await withCheckedContinuation { continuation in
            loadCountContinuations.append((expectedCount, continuation))
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    private func resumeLoadCountContinuations() {
        let ready = loadCountContinuations.filter { loadCount >= $0.0 }
        loadCountContinuations.removeAll { loadCount >= $0.0 }
        ready.forEach { $0.1.resume() }
    }
}

private actor RetryOperationGate {
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
