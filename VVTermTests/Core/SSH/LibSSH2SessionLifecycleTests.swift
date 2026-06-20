import XCTest
@testable import VVTerm

// Test Context:
// These tests protect the Swift boundary around libssh2 session ownership.
// They use a fake driver rather than real network or libssh2 calls so failures
// identify lifecycle regressions such as leaked sockets, double close paths, or
// missing raw error preservation. Update these tests only when the intended
// libssh2 session ownership contract changes.

final class LibSSH2SessionLifecycleTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        await KnownHostsStore.shared.remove(host: "ssh.example.com", port: 22)
    }

    override func tearDown() async throws {
        await KnownHostsStore.shared.remove(host: "ssh.example.com", port: 22)
        try await super.tearDown()
    }

    func testSessionInitFailureClosesConfiguredSocketExactlyOnce() async {
        // Given a driver that can open a socket but cannot create a libssh2 session.
        let driver = RecordingLibSSH2SessionDriver(sessionInitResult: nil)
        let session = SSHSession(config: .libSSH2LifecycleTest, driver: driver)

        // When connect reaches session initialization and fails.
        do {
            try await session.connect()
            XCTFail("Expected libssh2 session initialization to fail")
        } catch {
            // The assertion below verifies the resource ownership contract.
        }

        // Then the configured socket is closed exactly once, with no follow-up
        // cleanup close against the same descriptor.
        let closedSockets = driver.closedSockets()
        XCTAssertEqual(
            closedSockets,
            [RecordingLibSSH2SessionDriver.testSocket],
            "Session initialization failure must close the configured socket exactly once"
        )
    }

    func testTimeoutAbortClosesSocketDuringBlockingHandshake() async throws {
        // Given a real file descriptor owned by SSHSession and a fake libssh2
        // handshake that does not return until that descriptor is closed.
        var descriptors = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors), 0)
        defer {
            Darwin.close(descriptors[0])
            Darwin.close(descriptors[1])
        }

        let driver = RecordingLibSSH2SessionDriver(
            sessionInitResult: OpaquePointer(bitPattern: 0x1),
            connectedSocket: descriptors[0],
            handshakeBehavior: .waitForSocketClose
        )
        let session = SSHSession(config: .libSSH2LifecycleTest, driver: driver)

        // When the timeout fires while connect is inside the blocking handshake.
        do {
            try await SSHClient.runWithTimeout(
                .milliseconds(25),
                operation: {
                    try await session.connect()
                },
                onTimeout: {
                    session.abort()
                }
            )
            XCTFail("Expected SSH connect to time out")
        } catch SSHError.timeout {
            // The assertion below verifies the abort hook.
        } catch {
            XCTFail("Expected SSHError.timeout, got \(error)")
        }

        // Then the timeout path closes the descriptor that the blocking
        // handshake is waiting on.
        XCTAssertTrue(
            driver.waitForObservedSocketAbort(timeout: .milliseconds(200)),
            "Timeout should abort the session socket while handshake is blocked"
        )
    }

    func testPublicKeyAuthFailurePreservesRawLibSSH2Error() async {
        // Given a fake libssh2 driver that reaches public-key auth and reports
        // the same callback/protocol failure observed in production logs.
        let rawAuthError = LibSSH2RawError(
            operation: .authentication,
            code: LIBSSH2_ERROR_PUBLICKEY_UNVERIFIED,
            message: "Callback returned error"
        )
        let driver = RecordingLibSSH2SessionDriver(
            sessionInitResult: OpaquePointer(bitPattern: 0x1),
            authMethods: .methods("publickey"),
            publicKeyAuthResult: .failure(rawAuthError)
        )
        let session = SSHSession(config: .libSSH2AuthLifecycleTest, driver: driver)

        // When authentication fails for a libssh2 callback/protocol reason.
        do {
            try await session.connect()
            XCTFail("Expected raw libssh2 authentication failure")
        } catch SSHError.libssh2(let rawError) {
            // Then the internal error keeps the libssh2 operation, raw code,
            // and message instead of collapsing to generic bad credentials.
            XCTAssertEqual(rawError.operation, .authentication)
            XCTAssertEqual(rawError.code, LIBSSH2_ERROR_PUBLICKEY_UNVERIFIED)
            XCTAssertEqual(rawError.message, "Callback returned error")
        } catch {
            XCTFail("Expected SSHError.libssh2, got \(error)")
        }
    }

    func testAuthMethodDiscoveryFailurePreservesRawLibSSH2Error() async {
        // Given libssh2 fails before an auth method can be selected.
        let rawAuthError = LibSSH2RawError(
            operation: .authentication,
            code: LIBSSH2_ERROR_SOCKET_RECV,
            message: "transport closed while reading auth methods"
        )
        let driver = RecordingLibSSH2SessionDriver(
            sessionInitResult: OpaquePointer(bitPattern: 0x1),
            authMethods: .failure(rawAuthError),
            publicKeyAuthResult: .rejected
        )
        let session = SSHSession(config: .libSSH2AuthLifecycleTest, driver: driver)

        // When the connection reaches auth method discovery.
        do {
            try await session.connect()
            XCTFail("Expected raw libssh2 authentication discovery failure")
        } catch SSHError.libssh2(let rawError) {
            // Then the raw discovery failure is preserved before any later
            // auth attempt can overwrite the diagnostic.
            XCTAssertEqual(rawError.operation, .authentication)
            XCTAssertEqual(rawError.code, LIBSSH2_ERROR_SOCKET_RECV)
            XCTAssertEqual(rawError.message, "transport closed while reading auth methods")
        } catch {
            XCTFail("Expected SSHError.libssh2, got \(error)")
        }
    }

    func testCredentialRejectionRemainsAuthenticationFailed() async {
        // Given a server that advertises public-key auth but rejects the key as
        // normal bad credentials.
        let driver = RecordingLibSSH2SessionDriver(
            sessionInitResult: OpaquePointer(bitPattern: 0x1),
            authMethods: .methods("publickey"),
            publicKeyAuthResult: .rejected
        )
        let session = SSHSession(config: .libSSH2AuthLifecycleTest, driver: driver)

        // When auth is rejected without a lower-level libssh2 failure.
        do {
            try await session.connect()
            XCTFail("Expected generic authentication failure")
        } catch SSHError.authenticationFailed {
            // Then user-facing credential rejection behavior is preserved.
        } catch {
            XCTFail("Expected SSHError.authenticationFailed, got \(error)")
        }
    }
}

private extension SSHSessionConfig {
    static var libSSH2LifecycleTest: SSHSessionConfig {
        let serverId = UUID(uuidString: "00000000-0000-0000-0000-000000000010")!
        return SSHSessionConfig(
            host: "ssh.example.com",
            port: 22,
            dialHost: "ssh.example.com",
            dialPort: 22,
            hostKeyHost: "ssh.example.com",
            hostKeyPort: 22,
            username: "root",
            connectionMode: .standard,
            authMethod: .sshKey,
            credentials: ServerCredentials(
                serverId: serverId,
                password: nil,
                privateKey: nil,
                publicKey: nil,
                passphrase: nil,
                cloudflareClientID: nil,
                cloudflareClientSecret: nil
            )
        )
    }

    static var libSSH2AuthLifecycleTest: SSHSessionConfig {
        let serverId = UUID(uuidString: "00000000-0000-0000-0000-000000000011")!
        return SSHSessionConfig(
            host: "ssh.example.com",
            port: 22,
            dialHost: "ssh.example.com",
            dialPort: 22,
            hostKeyHost: "ssh.example.com",
            hostKeyPort: 22,
            username: "root",
            connectionMode: .standard,
            authMethod: .sshKey,
            credentials: ServerCredentials(
                serverId: serverId,
                password: nil,
                privateKey: Data("private-key".utf8),
                publicKey: Data("public-key".utf8),
                passphrase: nil,
                cloudflareClientID: nil,
                cloudflareClientSecret: nil
            )
        )
    }
}

private final class RecordingLibSSH2SessionDriver: @unchecked Sendable, LibSSH2SessionDriving {
    static let testSocket: Int32 = 42

    enum HandshakeBehavior {
        case succeed
        case waitForSocketClose
    }

    enum AuthResult {
        case success
        case rejected
        case failure(LibSSH2RawError)

        var code: Int32 {
            switch self {
            case .success:
                return 0
            case .rejected:
                return LIBSSH2_ERROR_AUTHENTICATION_FAILED
            case .failure(let rawError):
                return rawError.code
            }
        }
    }

    enum AuthMethodsResult {
        case methods(String)
        case unavailable
        case failure(LibSSH2RawError)
    }

    private let sessionInitResult: OpaquePointer?
    private let connectedSocket: Int32
    private let handshakeBehavior: HandshakeBehavior
    private let authMethodsResult: AuthMethodsResult
    private let publicKeyAuthResult: AuthResult
    private let lock = NSLock()
    private var closedSocketDescriptors: [Int32] = []
    private var observedSocketAbort = false

    init(
        sessionInitResult: OpaquePointer?,
        connectedSocket: Int32 = testSocket,
        handshakeBehavior: HandshakeBehavior = .succeed,
        authMethods: AuthMethodsResult = .unavailable,
        publicKeyAuthResult: AuthResult = .success
    ) {
        self.sessionInitResult = sessionInitResult
        self.connectedSocket = connectedSocket
        self.handshakeBehavior = handshakeBehavior
        self.authMethodsResult = authMethods
        self.publicKeyAuthResult = publicKeyAuthResult
    }

    func closedSockets() -> [Int32] {
        lock.lock()
        defer { lock.unlock() }
        return closedSocketDescriptors
    }

    func waitForObservedSocketAbort(timeout: Duration) -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            lock.lock()
            let observed = observedSocketAbort
            lock.unlock()
            if observed {
                return true
            }
            usleep(1_000)
        }
        return false
    }

    nonisolated func ensureRuntimeInitialized() throws {}

    nonisolated func connectSocket(host: String, port: Int) throws -> LibSSH2ConnectedSocket {
        LibSSH2ConnectedSocket(descriptor: connectedSocket, peerAddress: "203.0.113.10")
    }

    nonisolated func configureInteractiveSocket(_ socket: Int32) {}

    nonisolated func closeSocket(_ socket: Int32) {
        lock.lock()
        defer { lock.unlock() }
        closedSocketDescriptors.append(socket)
    }

    nonisolated func makeSession(abstract: UnsafeMutableRawPointer?) -> OpaquePointer? {
        sessionInitResult
    }

    nonisolated func setMethodPreference(session: OpaquePointer, method: Int32, preferences: String) {}

    nonisolated func setBlocking(session: OpaquePointer, isBlocking: Bool) {}

    nonisolated func handshake(session: OpaquePointer, socket: Int32) -> Int32 {
        guard handshakeBehavior == .waitForSocketClose else {
            return 0
        }

        let deadline = ContinuousClock.now.advanced(by: .milliseconds(500))
        while ContinuousClock.now < deadline {
            errno = 0
            if fcntl(socket, F_GETFD) == -1, errno == EBADF {
                lock.lock()
                observedSocketAbort = true
                lock.unlock()
                return LIBSSH2_ERROR_SOCKET_DISCONNECT
            }
            usleep(1_000)
        }

        return 0
    }

    nonisolated func lastError(
        session: OpaquePointer,
        operation: LibSSH2RawError.Operation,
        fallbackCode: Int32
    ) -> LibSSH2RawError {
        if case .authentication = operation,
           case .failure(let rawError) = authMethodsResult {
            return rawError
        }
        if case .authentication = operation,
           case .failure(let rawError) = publicKeyAuthResult {
            return rawError
        }
        return LibSSH2RawError(operation: operation, code: fallbackCode, message: nil)
    }

    nonisolated func hostKeyFingerprint(session: OpaquePointer) throws -> (fingerprint: String, keyType: Int) {
        ("SHA256:test-host-key", 1)
    }

    nonisolated func supportedAuthenticationMethods(
        session: OpaquePointer,
        username: String
    ) -> LibSSH2AuthenticationMethodDiscoveryResult {
        switch authMethodsResult {
        case .methods(let methods):
            return .methods(methods)
        case .unavailable:
            return .unavailable
        case .failure(let rawError):
            return .failure(rawError)
        }
    }

    nonisolated func isAuthenticated(session: OpaquePointer) -> Bool {
        false
    }

    nonisolated func authenticateWithPassword(session: OpaquePointer, username: String, password: String) -> Int32 {
        LIBSSH2_ERROR_AUTHENTICATION_FAILED
    }

    nonisolated func authenticateWithKeyboardInteractive(
        session: OpaquePointer,
        username: String,
        callback: LibSSH2KeyboardInteractiveCallback
    ) -> Int32 {
        LIBSSH2_ERROR_AUTHENTICATION_FAILED
    }

    nonisolated func authenticateWithPublicKey(
        session: OpaquePointer,
        username: String,
        keyData: Data,
        publicKeyData: Data?,
        passphrase: String?
    ) -> Int32 {
        publicKeyAuthResult.code
    }

    nonisolated func disconnect(
        session: OpaquePointer,
        reasonCode: Int32,
        description: String,
        language: String
    ) -> Int32 {
        0
    }

    nonisolated func free(session: OpaquePointer) -> Int32 {
        0
    }
}
