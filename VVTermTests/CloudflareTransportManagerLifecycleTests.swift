import Cloudflared
import Foundation
import Testing
@testable import VVTerm

// Test Context:
// These tests protect CloudflareTransportManager as the owner of Cloudflared
// tunnel session lifecycle. Fakes avoid real Cloudflare auth, network tunnels,
// URLSession metadata discovery, and Keychain token lookup. Update only if
// Cloudflare transport ownership intentionally moves to an equivalent
// connection infrastructure owner with awaited connect-failure cleanup.
struct CloudflareTransportManagerLifecycleTests {
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
    func oauthCompletionCallbacksAreTrackedAndSessionScoped() throws {
        let source = try source(
            at: sourceRoot().appendingPathComponent("VVTerm/Core/Network/Cloudflare/CloudflareOAuthFlow.swift")
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
        while url.lastPathComponent != "VVTermTests" {
            let next = url.deletingLastPathComponent()
            if next.path == url.path {
                throw SourceRootError.notFound
            }
            url = next
        }
        return url.deletingLastPathComponent()
    }

    private enum SourceRootError: Error {
        case notFound
    }
}

private actor FakeCloudflareTransportSession: CloudflareTransportSession {
    private var connectStarted = false
    private var connectReleased = false
    private var connectStartContinuations: [CheckedContinuation<Void, Never>] = []
    private var connectReleaseContinuations: [CheckedContinuation<Void, Never>] = []
    private var disconnects = 0

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
        return 12345
    }

    func disconnect() async {
        disconnects += 1
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

    func disconnectCallCount() -> Int {
        disconnects
    }
}
