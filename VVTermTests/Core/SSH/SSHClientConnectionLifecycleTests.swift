import XCTest
@testable import VVTerm

// Test Context:
// These tests protect SSHClient's ownership of in-flight SSHSession connection
// attempts. They use a fake libssh2 driver with a real local socketpair so the
// connect task can block in handshake, then verify disconnect does not report
// completion before pending connect cleanup has run. Update these tests only
// when SSHClient's pending-connect ownership contract intentionally changes.

final class SSHClientConnectionLifecycleTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        await trustLifecycleTestHost()
    }

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

    func testReconnectWaitsForActiveSessionDisconnectCleanup() async throws {
        // Given SSHClient owns an active SSHSession whose disconnect cleanup is
        // still running after the logical client has been marked disconnected.
        let firstDriver = RecordingLibSSH2SessionDriver(
            sessionInitResult: OpaquePointer(bitPattern: 0x1),
            authMethods: .methods("publickey"),
            publicKeyAuthResult: .success,
            shouldBlockDisconnect: true
        )
        let secondDriver = RecordingLibSSH2SessionDriver(
            sessionInitResult: OpaquePointer(bitPattern: 0x2),
            authMethods: .methods("publickey"),
            publicKeyAuthResult: .success
        )
        let sessionFactory = RecordingSSHSessionFactory([
            SSHSession(config: .libSSH2AuthLifecycleTest, driver: firstDriver),
            SSHSession(config: .libSSH2AuthLifecycleTest, driver: secondDriver)
        ])
        let client = SSHClient(
            sessionFactory: { _ in
                sessionFactory.makeSession()
            },
            disconnectTimeout: .seconds(2)
        )
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

        _ = try await client.connect(to: target, credentials: credentials)
        let disconnectTask = Task {
            await client.disconnect()
        }
        for _ in 0..<50 where firstDriver.disconnectCount() == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(
            firstDriver.disconnectCount(),
            1,
            "The first session should be inside disconnect cleanup before reconnect is requested."
        )

        // When reconnect is requested while the old session teardown is still
        // blocked inside the low-level owner.
        let reconnectTask = Task {
            try await client.connect(to: target, credentials: credentials)
        }
        try await Task.sleep(for: .milliseconds(100))

        // Then the new connect must wait for the active session cleanup owner
        // instead of creating a replacement session during teardown.
        XCTAssertEqual(
            sessionFactory.createdCount(),
            1,
            "Reconnect must not create a new SSHSession until the previous active session disconnect has completed."
        )

        firstDriver.releaseDisconnect()
        await disconnectTask.value
        _ = try await reconnectTask.value
        XCTAssertEqual(
            sessionFactory.createdCount(),
            2,
            "Reconnect should create the replacement SSHSession after the previous teardown completes."
        )
        await client.disconnect()
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

    func testCloudflareConnectIsBoundedByClientConnectTimeout() async throws {
        // Given Cloudflare tunnel setup has entered a subsystem that does not
        // return before the SSH client connect timeout.
        let cloudflareTransport = BlockingCloudflareTransportManager()
        let sessionFactory = CountingSSHSessionFactory()
        let client = SSHClient(
            sessionFactory: { config in
                sessionFactory.makeSession(config: config)
            },
            cloudflareTransportManager: cloudflareTransport,
            connectTimeout: .milliseconds(80)
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
        let startedAt = ContinuousClock.now

        // When the Cloudflare connect never produces a local tunnel endpoint.
        do {
            _ = try await AsyncTimeoutGate.run(
                timeout: .milliseconds(600),
                timeoutError: { SSHClientConnectionLifecycleTestError.cloudflareConnectEscapedTimeout }
            ) {
                try await client.connect(to: target, credentials: credentials)
            }
            XCTFail("Expected Cloudflare setup to be bounded by SSHClient.connect timeout")
        } catch SSHError.timeout {
            // Then the client returns the configured timeout before any
            // SSHSession exists and asks the Cloudflare owner to clean up.
        } catch SSHClientConnectionLifecycleTestError.cloudflareConnectEscapedTimeout {
            XCTFail("Cloudflare connect escaped SSHClient.connect timeout")
        } catch {
            XCTFail("Expected SSHError.timeout, got \(error)")
        }

        let elapsed = startedAt.duration(to: .now)
        XCTAssertLessThan(
            elapsed,
            .milliseconds(800),
            "Cloudflare setup should be covered by SSHClient.connect timeout."
        )
        XCTAssertEqual(
            sessionFactory.createdCount(),
            0,
            "Timed-out Cloudflare setup must not create an SSHSession without a tunnel endpoint."
        )
        let disconnectCount = await cloudflareTransport.disconnectCount()
        XCTAssertEqual(
            disconnectCount,
            1,
            "Timed-out Cloudflare setup should disconnect the Cloudflare owner exactly once."
        )
        await cloudflareTransport.releaseConnect()
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

    func testConnectTimeoutBoundsBlockedPendingSessionCleanup() async throws {
        // Given SSHClient has created a pending SSHSession whose libssh2
        // handshake times out, and whose disconnect cleanup ignores
        // cancellation until explicitly released.
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
        let pendingSession = SSHSession(config: .libSSH2LifecycleTest, driver: driver)
        let client = SSHClient(
            sessionFactory: { _ in pendingSession },
            connectTimeout: .milliseconds(80),
            disconnectTimeout: .milliseconds(80)
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
        let connectTask = Task {
            try await client.connect(to: target, credentials: credentials)
        }

        // When the connect timeout fires while pending session cleanup is
        // blocked.
        do {
            try await AsyncTimeoutGate.waitForTask(
                connectTask,
                timeout: .milliseconds(700),
                timeoutError: { SSHClientConnectionLifecycleTestError.connectTimeoutWaitedForCleanup }
            )
            XCTFail("Expected SSHClient.connect to throw its configured timeout")
        } catch SSHError.timeout {
            // Then the timeout path is bounded by SSHClient instead of waiting
            // forever for pending session cleanup to return.
        } catch SSHClientConnectionLifecycleTestError.connectTimeoutWaitedForCleanup {
            XCTFail("SSHClient.connect waited unboundedly for pending session cleanup after timeout")
        } catch {
            XCTFail("Expected SSHError.timeout, got \(error)")
        }

        let elapsed = startedAt.duration(to: .now)
        XCTAssertLessThan(
            elapsed,
            .milliseconds(500),
            "SSHClient.connect timeout should not be trapped behind blocked pending session cleanup."
        )
        XCTAssertEqual(
            driver.disconnectCount(),
            1,
            "Timed-out pending SSHSession should still enter cleanup exactly once."
        )

        driver.releaseDisconnect()
        _ = await connectTask.result
        await client.disconnect()
    }

    func testRunWithTimeoutReturnsWithoutWaitingForBlockedOperation() async throws {
        // Given a timeout-wrapped operation has entered a blocking subsystem
        // that does not observe Swift task cancellation.
        let operationStarted = DispatchSemaphore(value: 0)
        let timeoutTask = Task {
            try await SSHClient.runWithTimeout(.milliseconds(50)) {
                operationStarted.signal()
                blockCurrentThreadIgnoringCancellation()
            }
        }
        XCTAssertEqual(operationStarted.wait(timeout: .now() + 5), .success)
        let startedAt = ContinuousClock.now

        // When the timeout elapses before the operation can finish.
        do {
            _ = try await AsyncTimeoutGate.run(
                timeout: .milliseconds(350),
                timeoutError: { SSHClientConnectionLifecycleTestError.timeoutGateWaitedForBlockedOperation }
            ) {
                try await timeoutTask.value
            }
            XCTFail("Expected SSHClient.runWithTimeout to throw SSHError.timeout")
        } catch SSHError.timeout {
            // Then the timeout wrapper returns promptly instead of waiting for
            // the blocked operation task to unwind.
        } catch SSHClientConnectionLifecycleTestError.timeoutGateWaitedForBlockedOperation {
            XCTFail("SSHClient.runWithTimeout waited for a blocked operation after its timeout fired")
        } catch {
            XCTFail("Expected SSHError.timeout, got \(error)")
        }

        let elapsed = startedAt.duration(to: .now)
        XCTAssertLessThan(
            elapsed,
            .milliseconds(500),
            "SSHClient.runWithTimeout should not hang behind a blocked child task after the timeout fires."
        )
        timeoutTask.cancel()
    }

    func testShellStartTimeoutInvalidatesStaleSessionBeforeRetry() async throws {
        // Given SSH is connected, but shell startup enters a blocking libssh2
        // setup call that outlives the shell startup timeout.
        var firstDescriptors = [Int32](repeating: -1, count: 2)
        var secondDescriptors = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &firstDescriptors), 0)
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &secondDescriptors), 0)
        defer {
            Darwin.close(firstDescriptors[1])
            Darwin.close(secondDescriptors[1])
        }

        let firstDriver = RecordingLibSSH2SessionDriver(
            sessionInitResult: OpaquePointer(bitPattern: 0x1),
            connectedSocket: firstDescriptors[0],
            authMethods: .methods("publickey"),
            publicKeyAuthResult: .success,
            channelOpenResult: OpaquePointer(bitPattern: 0x44),
            execStartDelayMicroseconds: 1_000_000,
            execStartDelayCommandSubstring: "vvterm-block-shell-start",
            channelEOFResults: Array(repeating: true, count: 10)
        )
        let secondDriver = RecordingLibSSH2SessionDriver(
            sessionInitResult: OpaquePointer(bitPattern: 0x2),
            connectedSocket: secondDescriptors[0],
            authMethods: .methods("publickey"),
            publicKeyAuthResult: .success
        )
        let sessionFactory = RecordingSSHSessionFactory([
            SSHSession(config: .libSSH2AuthLifecycleTest, driver: firstDriver),
            SSHSession(config: .libSSH2AuthLifecycleTest, driver: secondDriver)
        ])
        let client = SSHClient(
            sessionFactory: { _ in
                sessionFactory.makeSession()
            },
            connectTimeout: .milliseconds(200),
            disconnectTimeout: .milliseconds(80),
            shellStartTimeout: .milliseconds(80)
        )
        let target = SSHConnectionTarget(host: "ssh.example.com", username: "root", authMethod: .sshKey)
        let credentials = ServerCredentials(
            serverId: UUID(),
            password: nil,
            privateKey: Data("private-key".utf8),
            publicKey: Data("public-key".utf8),
            passphrase: nil,
            cloudflareClientID: nil,
            cloudflareClientSecret: nil
        )

        do {
            _ = try await client.connect(to: target, credentials: credentials)
        } catch {
            XCTFail("connect should establish the first SSH session before shell timeout test, got \(error)")
            return
        }

        // When shell startup times out after aborting the socket.
        do {
            _ = try await client.startShell(startupCommand: "vvterm-block-shell-start")
            XCTFail("Expected shell startup timeout")
        } catch SSHError.timeout {
            // Then the timed-out SSHSession must not remain the active logical
            // connection for same-target retries.
        } catch {
            XCTFail("Expected SSHError.timeout, got \(error)")
        }

        let isConnectedAfterTimeout = await client.isConnected
        XCTAssertFalse(
            isConnectedAfterTimeout,
            "Shell startup timeout must invalidate the active SSHClient session."
        )

        do {
            _ = try await client.connect(to: target, credentials: credentials)
        } catch {
            XCTFail("retry should establish a fresh SSH session after shell startup timeout, got \(error)")
            return
        }
        XCTAssertEqual(
            sessionFactory.createdCount(),
            2,
            "Retry after shell startup timeout should create a fresh SSHSession instead of reusing the stale one."
        )
        await client.disconnect()
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

        do {
            _ = try await client.connect(to: target, credentials: credentials)
        } catch {
            XCTFail("connect should establish the SSH session before aborting shell startup, got \(error)")
            return
        }
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

}

private func trustLifecycleTestHost() async {
    let now = Date()
    await KnownHostsStore.shared.save(
        entry: KnownHostsManager.Entry(
            host: "ssh.example.com",
            port: 22,
            fingerprint: "SHA256:test-host-key",
            keyType: 1,
            addedAt: now,
            lastSeenAt: now
        )
    )
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

private final class CountingSSHSessionFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var createdSessions = 0

    func makeSession(config: SSHSessionConfig) -> SSHSession {
        lock.lock()
        createdSessions += 1
        lock.unlock()

        return SSHSession(
            config: config,
            driver: RecordingLibSSH2SessionDriver(sessionInitResult: OpaquePointer(bitPattern: 0x1))
        )
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
    private var disconnectInvocations = 0

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
        disconnectInvocations += 1
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

    func disconnectCount() -> Int {
        disconnectInvocations
    }
}

private enum SSHClientConnectionLifecycleTestError: Error {
    case timeoutGateWaitedForBlockedOperation
    case cloudflareConnectEscapedTimeout
    case connectTimeoutWaitedForCleanup
}

private func blockCurrentThreadIgnoringCancellation() {
    usleep(1_000_000)
}
