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

    private func makeCloudflareTarget() -> SSHConnectionTarget {
        SSHConnectionTarget(
            host: "ssh.example.com",
            username: "root",
            connectionMode: .cloudflare,
            cloudflareAccessMode: .serviceToken,
            cloudflareTeamDomainOverride: "team.cloudflareaccess.com"
        )
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
