import XCTest
@testable import VVTerm

// Test Context:
// These tests protect the Swift boundary around libssh2 session ownership.
// They use a fake driver rather than real network or libssh2 calls so failures
// identify lifecycle regressions such as leaked sockets, double close paths, or
// missing raw error preservation. Update these tests only when the intended
// libssh2 session ownership contract changes.

final class LibSSH2SessionLifecycleTests: XCTestCase {
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
}

private final class RecordingLibSSH2SessionDriver: @unchecked Sendable, LibSSH2SessionDriving {
    static let testSocket: Int32 = 42

    enum HandshakeBehavior {
        case succeed
        case waitForSocketClose
    }

    private let sessionInitResult: OpaquePointer?
    private let connectedSocket: Int32
    private let handshakeBehavior: HandshakeBehavior
    private let lock = NSLock()
    private var closedSocketDescriptors: [Int32] = []
    private var observedSocketAbort = false

    init(
        sessionInitResult: OpaquePointer?,
        connectedSocket: Int32 = testSocket,
        handshakeBehavior: HandshakeBehavior = .succeed
    ) {
        self.sessionInitResult = sessionInitResult
        self.connectedSocket = connectedSocket
        self.handshakeBehavior = handshakeBehavior
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
        LibSSH2RawError(operation: operation, code: fallbackCode, message: nil)
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
