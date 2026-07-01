import Cloudflared
import Foundation
import Testing
@testable import Waterm

// Test Context:
// These tests protect CloudflareTransportManager as the owner of Cloudflared
// tunnel session lifecycle. Fakes avoid real Cloudflare auth, network tunnels,
// URLSession metadata discovery, and Keychain token lookup. Update only if
// Cloudflare transport ownership intentionally moves to an equivalent
// connection infrastructure owner with awaited connect-failure cleanup.
struct CloudflareTransportManagerLifecycleTests {
    @Test
    func oauthSessionStateInvalidatesSupersededPendingStarts() {
        var state = CloudflareOAuthSessionLifecycleState()

        // Given an OAuth start request has reserved ownership before it creates
        // the platform session handle.
        let staleSessionID = state.beginStart()

        // When a newer start supersedes it during an actor await boundary.
        let currentSessionID = state.beginStart()

        // Then the older start can no longer publish a session or completion
        // result, and its late callback is explicitly ignored.
        let didIgnoreStaleCompletion = state.consumeIgnoredCompletion(staleSessionID)
        #expect(!state.isCurrent(staleSessionID))
        #expect(state.isCurrent(currentSessionID))
        #expect(
            didIgnoreStaleCompletion,
            "Superseded OAuth starts should ignore late ASWebAuthenticationSession completions."
        )
    }

    @Test
    func oauthSessionStateClearsOnlyCurrentCompletion() {
        var state = CloudflareOAuthSessionLifecycleState()
        let staleSessionID = state.beginStart()
        let currentSessionID = state.beginStart()

        // Given an older completion arrives after a newer session is current.
        state.finishIfCurrent(staleSessionID)

        // Then the current session remains owned until its own completion
        // arrives.
        #expect(state.isCurrent(currentSessionID))

        // When the current completion finishes.
        state.finishIfCurrent(currentSessionID)

        // Then no session remains current.
        #expect(!state.hasCurrentSession)
    }

    @Test
    func canceledConnectDisconnectsSessionBeforeReturning() async throws {
        let fakeSession = FakeCloudflareTransportSession()
        let manager = CloudflareTransportManager { _ in
            fakeSession
        }
        let target = makeCloudflareTarget()
        let credentials = ServerCredentials(
            serverId: UUID(),
            password: nil,
            privateKey: nil,
            publicKey: nil,
            passphrase: nil,
            cloudflareClientID: "client-id",
            cloudflareClientSecret: "client-secret"
        )

        // Given Cloudflare connect has created a session and is suspended
        // inside the tunnel connect operation.
        let connectTask = Task {
            try await manager.connect(target: target, credentials: credentials)
        }
        await fakeSession.waitForConnectStart()

        // When the parent SSH connection task is cancelled before connect returns.
        connectTask.cancel()
        await fakeSession.releaseConnect()

        do {
            _ = try await connectTask.value
            Issue.record("Expected canceled Cloudflare connect to throw CancellationError")
        } catch is CancellationError {
            // Then cancellation remains cancellation, not a tunnel failure.
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }

        // And the manager has awaited tunnel disconnect before connect returns.
        #expect(
            await fakeSession.disconnectCallCount() == 1,
            "Canceled Cloudflare connect should disconnect the created session before returning."
        )
    }

    @Test
    func staleOverlappingConnectCannotOverwriteActiveSession() async throws {
        let firstSession = FakeCloudflareTransportSession(localPort: 1111)
        let secondSession = FakeCloudflareTransportSession(localPort: 2222)
        let sessionFactory = FakeCloudflareTransportSessionFactory([
            firstSession,
            secondSession
        ])
        let manager = CloudflareTransportManager { authProvider in
            sessionFactory.makeSession(authProvider: authProvider)
        }
        let target = makeCloudflareTarget()
        let credentials = ServerCredentials(
            serverId: UUID(),
            password: nil,
            privateKey: nil,
            publicKey: nil,
            passphrase: nil,
            cloudflareClientID: "client-id",
            cloudflareClientSecret: "client-secret"
        )

        // Given one Cloudflare connect is suspended after creating its tunnel
        // session, and a newer connect starts on the same manager.
        let firstConnect = Task {
            try await manager.connect(target: target, credentials: credentials)
        }
        await firstSession.waitForConnectStart()

        let secondConnect = Task {
            try await manager.connect(target: target, credentials: credentials)
        }
        await secondSession.waitForConnectStart()

        // When the newer connect completes first, then the older connect
        // completes after it has already been superseded.
        await secondSession.releaseConnect()
        let secondPort = try await secondConnect.value
        await firstSession.releaseConnect()

        do {
            _ = try await firstConnect.value
            Issue.record("Expected stale Cloudflare connect to throw CancellationError")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }

        // Then the stale session cleans itself up and cannot replace the newer
        // active session owned by the manager.
        #expect(secondPort == 2222)
        #expect(
            await firstSession.disconnectCallCount() == 1,
            "A superseded Cloudflare connect should disconnect its stale tunnel."
        )
        #expect(
            await secondSession.disconnectCallCount() == 0,
            "The latest Cloudflare connect should remain active after an older connect finishes."
        )

        await manager.disconnect()
        #expect(
            await secondSession.disconnectCallCount() == 1,
            "Disconnect should target the latest active Cloudflare session."
        )
    }

    @Test
    func disconnectCleansInFlightConnectSessionBeforeReturning() async throws {
        let fakeSession = FakeCloudflareTransportSession()
        let manager = CloudflareTransportManager { _ in
            fakeSession
        }
        let target = makeCloudflareTarget()
        let credentials = ServerCredentials(
            serverId: UUID(),
            password: nil,
            privateKey: nil,
            publicKey: nil,
            passphrase: nil,
            cloudflareClientID: "client-id",
            cloudflareClientSecret: "client-secret"
        )

        // Given Cloudflare connect has created its tunnel session, but the
        // tunnel connect operation has not returned a local port yet.
        let connectTask = Task {
            try await manager.connect(target: target, credentials: credentials)
        }
        await fakeSession.waitForConnectStart()

        // When teardown is requested while connect is still in flight.
        await manager.disconnect()

        // Then disconnect owns that in-flight session and awaits cleanup before
        // returning instead of leaving it for a late connect continuation.
        #expect(
            await fakeSession.disconnectCallCount() == 1,
            "Disconnect should clean an in-flight Cloudflare tunnel session before returning."
        )

        await fakeSession.releaseConnect()
        do {
            _ = try await connectTask.value
            Issue.record("Expected disconnected in-flight Cloudflare connect to throw CancellationError")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }

        #expect(
            await fakeSession.disconnectCallCount() == 1,
            "Late completion of a disconnected in-flight connect should not double-disconnect the session."
        )
    }

    @Test
    func disconnectTimeoutReturnsWhenSessionDisconnectDoesNotResume() async throws {
        let fakeSession = FakeCloudflareTransportSession(disconnectStartsReleased: false)
        let manager = CloudflareTransportManager(disconnectTimeout: .milliseconds(100)) { _ in
            fakeSession
        }
        let target = makeCloudflareTarget()
        let credentials = ServerCredentials(
            serverId: UUID(),
            password: nil,
            privateKey: nil,
            publicKey: nil,
            passphrase: nil,
            cloudflareClientID: "client-id",
            cloudflareClientSecret: "client-secret"
        )
        let disconnectCompletion = AsyncCompletionProbe()

        // Given Cloudflare connect has published an active tunnel session.
        let connectTask = Task {
            try await manager.connect(target: target, credentials: credentials)
        }
        await fakeSession.waitForConnectStart()
        await fakeSession.releaseConnect()
        _ = try await connectTask.value

        // When the underlying Cloudflared session never returns from disconnect.
        let disconnectTask = Task {
            await manager.disconnect()
            await disconnectCompletion.markCompleted()
        }
        await fakeSession.waitForDisconnectStart()
        try await Task.sleep(for: .milliseconds(250))

        // Then the manager-level timeout still returns to its caller instead of
        // waiting forever for a cancellation-uncooperative child task.
        #expect(
            await disconnectCompletion.isCompleted,
            "Cloudflare disconnect timeout should return even if the session disconnect task does not resume."
        )

        await fakeSession.releaseDisconnect()
        await disconnectTask.value
    }

    @Test
    func lateConnectAfterDisconnectTimeoutStillCleansTunnel() async throws {
        let fakeSession = FakeCloudflareTransportSession(disconnectStartsReleased: false)
        let manager = CloudflareTransportManager(disconnectTimeout: .milliseconds(80)) { _ in
            fakeSession
        }
        let target = makeCloudflareTarget()
        let credentials = ServerCredentials(
            serverId: UUID(),
            password: nil,
            privateKey: nil,
            publicKey: nil,
            passphrase: nil,
            cloudflareClientID: "client-id",
            cloudflareClientSecret: "client-secret"
        )
        let disconnectCompletion = AsyncCompletionProbe()

        // Given a Cloudflare connect has created a tunnel session, and manager
        // teardown times out while that session's disconnect is still suspended.
        let connectTask = Task {
            try await manager.connect(target: target, credentials: credentials)
        }
        await fakeSession.waitForConnectStart()

        let disconnectTask = Task {
            await manager.disconnect()
            await disconnectCompletion.markCompleted()
        }
        await fakeSession.waitForDisconnectStart()
        try await Task.sleep(for: .milliseconds(180))
        #expect(
            await disconnectCompletion.isCompleted,
            "Cloudflare disconnect should return after its timeout even when a connecting session ignores cancellation."
        )

        // When the original connect later succeeds, it is stale and must still
        // try to clean up the now-live tunnel instead of treating the timed-out
        // disconnect attempt as completed ownership.
        await fakeSession.releaseConnect()
        try await waitUntilDisconnectRetryIsObserved(on: fakeSession)
        #expect(
            await fakeSession.disconnectCallCount() == 2,
            "A late-successful in-flight Cloudflare connect should perform a second cleanup attempt if the manager-level disconnect already timed out."
        )

        await fakeSession.releaseDisconnect()
        await disconnectTask.value

        do {
            _ = try await connectTask.value
            Issue.record("Expected stale Cloudflare connect to throw CancellationError")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }
    }

    @Test
    func oauthCompletionCallbacksAreTrackedAndSessionScoped() throws {
        let source = try source(
            at: sourceRoot().appendingPathComponent("Waterm/Core/Network/Cloudflare/CloudflareOAuthFlow.swift")
        )

        #expect(
            source.contains("CloudflareOAuthCompletionTaskRegistry"),
            "Cloudflare OAuth should own a registry for completion callbacks that hop out of ASWebAuthenticationSession."
        )
        #expect(
            source.contains("private typealias CloudflareOAuthCompletionTaskRegistry = AsyncCallbackTaskRegistry"),
            "The completion task registry should use the shared callback task owner instead of duplicating lock bookkeeping."
        )
        #expect(
            source.contains("struct CloudflareWebAuthenticationSessionHandle: @unchecked Sendable"),
            "ASWebAuthenticationSession should be wrapped before crossing actor/MainActor boundaries."
        )
        #expect(
            source.contains("private var currentSession: CloudflareWebAuthenticationSessionHandle?"),
            "Cloudflare OAuth actor should store the sendable session handle instead of raw ASWebAuthenticationSession."
        )
        #expect(
            !source.contains("private var currentSession: ASWebAuthenticationSession?"),
            "Raw ASWebAuthenticationSession should not be actor state sent into MainActor closures."
        )
        #expect(
            !source.contains("MainActor.run {\n            session."),
            "OAuth session start/configure/cancel should go through the session handle rather than sending actor-owned session into MainActor."
        )
        #expect(
            source.contains("completionTasks.track"),
            "The ASWebAuthenticationSession completion should publish its lifecycle work before returning."
        )
        #expect(
            source.contains("currentSessionID"),
            "OAuth completion handling should be scoped to the session that created the callback."
        )
        #expect(
            source.contains("ignoredCompletionSessionIDs"),
            "Canceled or restarted sessions should invalidate their late completions explicitly."
        )
        #expect(
            source.contains("handleCompletion(sessionID: sessionID"),
            "The completion callback should pass the originating session ID into actor-owned state."
        )
        #expect(
            !source.contains("[weak self] _, error in"),
            "OAuth auth-state completion must not be skipped because a weak self capture became nil."
        )
        #expect(
            !source.contains("ignoreNextCompletion"),
            "A single global ignore flag is not enough to isolate overlapping OAuth sessions."
        )
    }

    private func makeCloudflareTarget() -> SSHConnectionTarget {
        SSHConnectionTarget(
            host: "ssh.example.com",
            username: "root",
            connectionMode: .cloudflare,
            cloudflareAccessMode: .serviceToken,
            cloudflareTeamDomainOverride: "team.cloudflareaccess.com"
        )
    }

    private func source(at url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    private func sourceRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.lastPathComponent != "WatermTests" {
            let next = url.deletingLastPathComponent()
            if next.path == url.path {
                throw SourceRootError.notFound
            }
            url = next
        }
        return url.deletingLastPathComponent()
    }

    private func waitUntilDisconnectRetryIsObserved(
        on session: FakeCloudflareTransportSession
    ) async throws {
        let clock = ContinuousClock()
        let startedAt = clock.now

        while startedAt.duration(to: clock.now) < .milliseconds(300) {
            if await session.disconnectCallCount() >= 2 {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private enum SourceRootError: Error {
        case notFound
    }
}

private final class FakeCloudflareTransportSessionFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: [FakeCloudflareTransportSession]

    init(_ sessions: [FakeCloudflareTransportSession]) {
        self.sessions = sessions
    }

    func makeSession(authProvider: any AuthProviding) -> any CloudflareTransportSession {
        lock.withLock {
            sessions.removeFirst()
        }
    }
}

private actor FakeCloudflareTransportSession: CloudflareTransportSession {
    private let localPort: UInt16
    private var connectStarted = false
    private var connectReleased = false
    private var disconnectStarted = false
    private var disconnectReleased: Bool
    private var connectStartContinuations: [CheckedContinuation<Void, Never>] = []
    private var connectReleaseContinuations: [CheckedContinuation<Void, Never>] = []
    private var disconnectStartContinuations: [CheckedContinuation<Void, Never>] = []
    private var disconnectReleaseContinuations: [CheckedContinuation<Void, Never>] = []
    private var disconnects = 0

    init(localPort: UInt16 = 12345, disconnectStartsReleased: Bool = true) {
        self.localPort = localPort
        self.disconnectReleased = disconnectStartsReleased
    }

    func connect(hostname: String, method: Cloudflared.AuthMethod) async throws -> UInt16 {
        connectStarted = true
        connectStartContinuations.forEach { $0.resume() }
        connectStartContinuations.removeAll()

        if !connectReleased {
            await withCheckedContinuation { continuation in
                connectReleaseContinuations.append(continuation)
            }
        }

        try Task.checkCancellation()
        return localPort
    }

    func disconnect() async {
        disconnects += 1
        disconnectStarted = true
        disconnectStartContinuations.forEach { $0.resume() }
        disconnectStartContinuations.removeAll()

        if !disconnectReleased {
            await withCheckedContinuation { continuation in
                disconnectReleaseContinuations.append(continuation)
            }
        }
    }

    func waitForConnectStart() async {
        guard !connectStarted else { return }
        await withCheckedContinuation { continuation in
            connectStartContinuations.append(continuation)
        }
    }

    func releaseConnect() {
        connectReleased = true
        connectReleaseContinuations.forEach { $0.resume() }
        connectReleaseContinuations.removeAll()
    }

    func waitForDisconnectStart() async {
        guard !disconnectStarted else { return }
        await withCheckedContinuation { continuation in
            disconnectStartContinuations.append(continuation)
        }
    }

    func releaseDisconnect() {
        disconnectReleased = true
        disconnectReleaseContinuations.forEach { $0.resume() }
        disconnectReleaseContinuations.removeAll()
    }

    func disconnectCallCount() -> Int {
        disconnects
    }
}

private actor AsyncCompletionProbe {
    private var completed = false

    var isCompleted: Bool {
        completed
    }

    func markCompleted() {
        completed = true
    }
}
