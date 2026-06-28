import XCTest
@testable import VVTerm

// Test Context:
// These tests protect SSHClient's ownership of in-flight SSHSession connection
// attempts. They use a fake libssh2 driver with a real local socketpair so the
// connect task can block in handshake, then verify disconnect does not report
// completion before pending connect cleanup has run. Update these tests only
// when SSHClient's pending-connect ownership contract intentionally changes.

final class SSHClientConnectionLifecycleTests: XCTestCase {
    func testDisconnectWaitsForPendingConnectCleanupBeforeReturning() async throws {
        // Given SSHClient owns a pending SSHSession connect that is blocked
        // inside libssh2 handshake, and that session cleanup is deliberately
        // held after abort.
        var descriptors = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors), 0)
        defer {
            Darwin.close(descriptors[0])
            Darwin.close(descriptors[1])
        }

        let driver = RecordingLibSSH2SessionDriver(
            sessionInitResult: OpaquePointer(bitPattern: 0x1),
            connectedSocket: descriptors[0],
            handshakeBehavior: .waitForSocketClose,
            shouldBlockDisconnect: true
        )
        defer { driver.releaseDisconnect() }

        let pendingSession = SSHSession(config: .libSSH2LifecycleTest, driver: driver)
        let client = SSHClient(sessionFactory: { _ in pendingSession })
        let target = SSHConnectionTarget(host: "ssh.example.com", username: "root")
        let credentials = ServerCredentials(
            serverId: UUID(),
            password: "secret",
            privateKey: nil,
            publicKey: nil,
            passphrase: nil,
            cloudflareClientID: nil,
            cloudflareClientSecret: nil
        )

        let connectTask = Task {
            try await client.connect(to: target, credentials: credentials)
        }
        defer {
            connectTask.cancel()
        }

        for _ in 0..<50 where !driver.sessionAbstractWasProvided() {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(
            driver.sessionAbstractWasProvided(),
            "Connect task should reach libssh2 session setup before disconnect is requested."
        )

        // When disconnect is requested while the connect task is still cleaning
        // up the pending session.
        let marker = DisconnectReturnMarker()
        let disconnectTask = Task {
            await client.disconnect()
            await marker.markReturned()
        }

        for _ in 0..<50 where driver.disconnectCount() == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(
            driver.disconnectCount(),
            1,
            "Pending connect cleanup should enter SSHSession.disconnect after aborting the blocked handshake."
        )

        // Then SSHClient.disconnect is still waiting for that pending connect
        // cleanup instead of reporting the client closed early.
        let hasReturnedBeforeRelease = await marker.hasReturned
        XCTAssertFalse(
            hasReturnedBeforeRelease,
            "SSHClient.disconnect must wait for pending connect cleanup before returning."
        )

        driver.releaseDisconnect()
        await disconnectTask.value
        let hasReturnedAfterRelease = await marker.hasReturned
        XCTAssertTrue(hasReturnedAfterRelease)
        _ = await connectTask.result
    }
}

private actor DisconnectReturnMarker {
    private(set) var hasReturned = false

    func markReturned() {
        hasReturned = true
    }
}
