import XCTest
@testable import VVTerm

// Test Context:
// These tests protect SSHClient's ownership of in-flight SSHSession connection
// attempts. They use a fake libssh2 driver with a real local socketpair so the
// connect task can block in handshake, then verify disconnect does not report
// completion before pending connect cleanup has run. Update these tests only
// when SSHClient's pending-connect ownership contract intentionally changes.

final class SSHClientConnectionLifecycleTests: XCTestCase {
    func testConcurrentSameTargetConnectsShareInFlightPreparation() async throws {
        // Given the first connect can suspend in pre-connect cleanup before an
        // SSHSession is created.
        var firstDescriptors = [Int32](repeating: -1, count: 2)
        var secondDescriptors = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &firstDescriptors), 0)
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &secondDescriptors), 0)
        defer {
            Darwin.close(firstDescriptors[0])
            Darwin.close(firstDescriptors[1])
            Darwin.close(secondDescriptors[0])
            Darwin.close(secondDescriptors[1])
        }

        let firstDriver = RecordingLibSSH2SessionDriver(
            sessionInitResult: OpaquePointer(bitPattern: 0x1),
            connectedSocket: firstDescriptors[0],
            handshakeBehavior: .waitForSocketClose
        )
        let secondDriver = RecordingLibSSH2SessionDriver(
            sessionInitResult: OpaquePointer(bitPattern: 0x2),
            connectedSocket: secondDescriptors[0],
            handshakeBehavior: .waitForSocketClose
        )
        let sessionFactory = RecordingSSHSessionFactory([
            SSHSession(config: .libSSH2AuthLifecycleTest, driver: firstDriver),
            SSHSession(config: .libSSH2AuthLifecycleTest, driver: secondDriver)
        ])
        let client = SSHClient(sessionFactory: { _ in
            sessionFactory.makeSession()
        })
        let target = SSHConnectionTarget(
            host: "ssh.example.com",
            username: "root",
            authMethod: .sshKey
        )
        let credentials = ServerCredentials(
            serverId: UUID(),
            password: nil,
            privateKey: Data("private-key".utf8),
            publicKey: Data("public-key".utf8),
            passphrase: nil,
            cloudflareClientID: nil,
            cloudflareClientSecret: nil
        )

        let firstConnect = Task {
            try await client.connect(to: target, credentials: credentials)
        }
        await Task.yield()

        // When a second caller asks for the same connection while preparation
        // is still in flight.
        let secondConnect = Task {
            try await client.connect(to: target, credentials: credentials)
        }
        try await Task.sleep(for: .milliseconds(50))

        // Then it must join the existing in-flight connect instead of creating
        // an independent SSHSession that would have no single owner.
        XCTAssertEqual(
            sessionFactory.createdCount(),
            1,
            "Concurrent same-target connects should share the in-flight SSHClient connect task before SSHSession creation."
        )

        firstConnect.cancel()
        secondConnect.cancel()
        await client.disconnect()
        _ = await firstConnect.result
        _ = await secondConnect.result
    }

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

    func testDisconnectTearsDownCloudflarePreSessionConnectWithoutWaitingForConnectTask() async throws {
        // Given SSHClient is blocked in Cloudflare tunnel setup before any
        // SSHSession exists.
        let cloudflareTransport = BlockingCloudflareTransportManager()
        let client = SSHClient(
            sessionFactory: { SSHSession(config: $0) },
            cloudflareTransportManager: cloudflareTransport
        )
        let target = SSHConnectionTarget(
            host: "ssh.example.com",
            username: "root",
            connectionMode: .cloudflare,
            authMethod: .password,
            cloudflareAccessMode: .serviceToken,
            cloudflareTeamDomainOverride: "team.cloudflareaccess.com"
        )
        let credentials = ServerCredentials(
            serverId: UUID(),
            password: "secret",
            privateKey: nil,
            publicKey: nil,
            passphrase: nil,
            cloudflareClientID: "client-id",
            cloudflareClientSecret: "client-secret"
        )

        let connectTask = Task {
            try await client.connect(to: target, credentials: credentials)
        }
        defer {
            connectTask.cancel()
        }
        await cloudflareTransport.waitUntilConnectStarted()

        // When disconnect is requested while Cloudflare connect is still
        // blocked and no pending SSHSession cleanup exists yet.
        let marker = DisconnectReturnMarker()
        let disconnectTask = Task {
            await client.disconnect()
            await marker.markReturned()
        }

        // Then SSHClient must ask the Cloudflare owner to disconnect without
        // waiting for the pre-session connect task to return first.
        await cloudflareTransport.waitUntilDisconnectStarted()
        for _ in 0..<50 where !(await marker.hasReturned) {
            try await Task.sleep(for: .milliseconds(10))
        }
        let hasReturnedBeforeConnectRelease = await marker.hasReturned
        XCTAssertTrue(
            hasReturnedBeforeConnectRelease,
            "SSHClient.disconnect should not wait for a pre-session Cloudflare connect task before tearing down the tunnel owner."
        )

        await cloudflareTransport.releaseConnect()
        await disconnectTask.value
        _ = await connectTask.result
    }

    func testConnectUsesBoundedSocketDialTimeout() async throws {
        // Given the low-level TCP dialer does not return a connected socket
        // before the client-level connect timeout.
        let driver = RecordingLibSSH2SessionDriver(
            sessionInitResult: OpaquePointer(bitPattern: 0x1),
            connectSocketBehavior: .timeout
        )
        let client = SSHClient(
            sessionFactory: { config in
                SSHSession(config: config, driver: driver)
            },
            connectTimeout: .milliseconds(80)
        )
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
        let startedAt = ContinuousClock.now

        // When SSHClient starts a connection that stalls before libssh2 has a
        // socket-backed session to abort.
        do {
            _ = try await client.connect(to: target, credentials: credentials)
            XCTFail("Expected socket dial timeout to fail SSHClient.connect")
        } catch SSHError.timeout {
            // Then the configured connect timeout is enforced by the socket
            // dialer instead of relying on cancellation of a blocking connect.
        } catch {
            XCTFail("Expected SSHError.timeout, got \(error)")
        }

        let elapsed = startedAt.duration(to: .now)
        XCTAssertLessThan(
            elapsed,
            .milliseconds(500),
            "SSHClient.connect should return on its configured socket dial timeout, not on the OS TCP timeout."
        )
        XCTAssertEqual(
            driver.connectSocketTimeouts().map { Int(($0 * 1000).rounded()) },
            [80],
            "SSHClient should pass its connect timeout into the low-level socket dialer."
        )
    }

    func testStartShellRejectsAfterClientAbortBeforeReadingSession() async throws {
        // Given SSHClient owns a connected SSHSession whose shell startup would
        // otherwise succeed.
        let driver = RecordingLibSSH2SessionDriver(
            sessionInitResult: OpaquePointer(bitPattern: 0x1),
            authMethods: .methods("publickey"),
            publicKeyAuthResult: .success,
            channelOpenResult: OpaquePointer(bitPattern: 0x44)
        )
        let pendingSession = SSHSession(config: .libSSH2AuthLifecycleTest, driver: driver)
        let client = SSHClient(sessionFactory: { _ in pendingSession })
        let target = SSHConnectionTarget(host: "ssh.example.com", username: "root")
        let credentials = ServerCredentials(
            serverId: UUID(),
            password: nil,
            privateKey: Data("private-key".utf8),
            publicKey: Data("public-key".utf8),
            passphrase: nil,
            cloudflareClientID: nil,
            cloudflareClientSecret: nil
        )

        _ = try await client.connect(to: target, credentials: credentials)
        client.abort()

        // When shell startup is requested after disconnect intent has already
        // aborted the client but before actor reentrancy has cleared session.
        do {
            let shell = try await client.startShell()
            await client.closeShell(shell.id)
            XCTFail("Expected aborted SSHClient to reject shell startup")
        } catch SSHError.notConnected {
            // Then no shell can be created during the disconnect/teardown window.
        } catch {
            XCTFail("Expected SSHError.notConnected, got \(error)")
        }

        XCTAssertFalse(
            driver.channelEvents().contains(.startShell),
            "SSHClient.startShell should check abort state before using a stale session during teardown."
        )
        await client.disconnect()
    }

    func testPendingConnectCleanupUsesBoundedTimeoutGate() throws {
        let source = try String(
            contentsOf: sourceRoot().appendingPathComponent("VVTerm/Core/SSH/SSHClient.swift"),
            encoding: .utf8
        )
        let cleanupMethod = try sourceSlice(
            in: source,
            from: "    private func waitForPendingConnectCleanup",
            to: "    private func disconnectCloudflareTransport"
        )

        XCTAssertTrue(
            cleanupMethod.contains("SSHClient.waitForTaskCompletion(task, timeout: disconnectTimeout)"),
            "SSHClient pending connect cleanup should be bounded by the client disconnect timeout."
        )
        XCTAssertFalse(
            cleanupMethod.contains("await pendingConnectTask?.result"),
            "SSHClient.disconnect must not wait unboundedly on pending connect cleanup."
        )
    }
}

private final class RecordingSSHSessionFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: [SSHSession]
    private var createdSessions = 0

    init(_ sessions: [SSHSession]) {
        self.sessions = sessions
    }

    func makeSession() -> SSHSession {
        lock.lock()
        defer { lock.unlock() }
        createdSessions += 1
        return sessions.removeFirst()
    }

    func createdCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return createdSessions
    }
}

private actor DisconnectReturnMarker {
    private(set) var hasReturned = false

    func markReturned() {
        hasReturned = true
    }
}

private actor BlockingCloudflareTransportManager: CloudflareTransportManaging {
    private var connectStarted = false
    private var disconnectStarted = false
    private var connectStartedWaiters: [CheckedContinuation<Void, Never>] = []
    private var disconnectStartedWaiters: [CheckedContinuation<Void, Never>] = []
    private var connectReleaseContinuation: CheckedContinuation<Void, Never>?

    func connect(target: SSHConnectionTarget, credentials: ServerCredentials) async throws -> UInt16 {
        connectStarted = true
        connectStartedWaiters.forEach { $0.resume() }
        connectStartedWaiters.removeAll()

        await withCheckedContinuation { continuation in
            connectReleaseContinuation = continuation
        }
        try Task.checkCancellation()
        return 2200
    }

    func disconnect() async {
        disconnectStarted = true
        disconnectStartedWaiters.forEach { $0.resume() }
        disconnectStartedWaiters.removeAll()
    }

    func waitUntilConnectStarted() async {
        if connectStarted { return }
        await withCheckedContinuation { continuation in
            connectStartedWaiters.append(continuation)
        }
    }

    func waitUntilDisconnectStarted() async {
        if disconnectStarted { return }
        await withCheckedContinuation { continuation in
            disconnectStartedWaiters.append(continuation)
        }
    }

    func releaseConnect() {
        connectReleaseContinuation?.resume()
        connectReleaseContinuation = nil
    }
}

private func sourceSlice(in source: String, from start: String, to end: String) throws -> String {
    guard let startRange = source.range(of: start) else {
        throw SSHClientConnectionLifecycleTestError.sourceSliceNotFound
    }
    guard let endRange = source[startRange.lowerBound...].range(of: end) else {
        throw SSHClientConnectionLifecycleTestError.sourceSliceNotFound
    }
    return String(source[startRange.lowerBound..<endRange.lowerBound])
}

private func sourceRoot() throws -> URL {
    var url = URL(fileURLWithPath: #filePath)
    while url.lastPathComponent != "VVTermTests" {
        let next = url.deletingLastPathComponent()
        if next.path == url.path {
            throw SSHClientConnectionLifecycleTestError.sourceSliceNotFound
        }
        url = next
    }
    return url.deletingLastPathComponent()
}

private enum SSHClientConnectionLifecycleTestError: Error {
    case sourceSliceNotFound
}
