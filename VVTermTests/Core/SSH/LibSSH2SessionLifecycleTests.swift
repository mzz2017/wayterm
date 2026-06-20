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

    func testKeepAliveUsesDriverBoundary() async throws {
        // Given a connected session using the fake libssh2 driver.
        let driver = RecordingLibSSH2SessionDriver(
            sessionInitResult: OpaquePointer(bitPattern: 0x1),
            authMethods: .methods("publickey"),
            publicKeyAuthResult: .success
        )
        let session = SSHSession(config: .libSSH2AuthLifecycleTest, driver: driver)

        // When the session sends a keepalive after authentication.
        try await session.connect()
        await session.sendKeepAlive()

        // Then keepalive is routed through the injected driver boundary rather
        // than calling libssh2 directly from SSHSession.
        XCTAssertEqual(
            driver.keepAliveCount(),
            1,
            "Keepalive must route through the injected libssh2 driver"
        )
    }

    func testShellPtyFailureClosesAndFreesOpenedChannel() async {
        // Given a fake libssh2 driver that opens a shell channel but rejects
        // the PTY request before any shell process starts.
        let driver = RecordingLibSSH2SessionDriver(
            sessionInitResult: OpaquePointer(bitPattern: 0x1),
            authMethods: .methods("publickey"),
            publicKeyAuthResult: .success,
            channelOpenResult: OpaquePointer(bitPattern: 0x22),
            ptyResult: LIBSSH2_ERROR_CHANNEL_REQUEST_DENIED
        )
        let session = SSHSession(config: .libSSH2AuthLifecycleTest, driver: driver)

        // When shell startup fails after channel open.
        do {
            try await session.connect()
            _ = try await session.startShell(cols: 80, rows: 24)
            XCTFail("Expected PTY request failure")
        } catch SSHError.shellRequestFailed {
            // Then the existing user-facing shell error is preserved.
        } catch {
            XCTFail("Expected SSHError.shellRequestFailed, got \(error)")
        }

        // And the opened channel is closed and freed exactly once.
        XCTAssertEqual(
            driver.channelEvents(),
            [.openSession, .requestPty, .close, .free],
            "PTY failure must close and free the channel that startShell opened"
        )
    }

    func testShellWriteRetriesEAGAINAndWritesCopiedBytes() async throws {
        // Given a connected shell whose first write would block before the
        // remaining bytes can be written in two successful chunks.
        let bytes = Data("hello".utf8)
        let driver = RecordingLibSSH2SessionDriver(
            sessionInitResult: OpaquePointer(bitPattern: 0x1),
            authMethods: .methods("publickey"),
            publicKeyAuthResult: .success,
            channelOpenResult: OpaquePointer(bitPattern: 0x22),
            channelWriteResults: [
                Int(LIBSSH2_ERROR_EAGAIN),
                2,
                3
            ]
        )
        let session = SSHSession(config: .libSSH2AuthLifecycleTest, driver: driver)

        // When writing to the shell.
        try await session.connect()
        let shell = try await session.startShell(cols: 80, rows: 24)
        try await session.write(bytes, to: shell.id)
        await session.closeShell(shell.id)

        // Then the driver receives copied bytes and retry offsets; no unsafe
        // Data pointer is allowed to escape from the production driver method.
        XCTAssertEqual(
            driver.channelWriteCalls(),
            [
                .init(stream: 0, bytes: Array(bytes), offset: 0, remaining: 5),
                .init(stream: 0, bytes: Array(bytes), offset: 0, remaining: 5),
                .init(stream: 0, bytes: Array(bytes), offset: 2, remaining: 3)
            ],
            "EAGAIN should retry the same copied bytes before advancing the offset"
        )
    }

    func testShellWriteEAGAINLoopStopsWhenTaskIsCancelled() async throws {
        // Given a connected shell whose channel write keeps reporting EAGAIN.
        // This reproduces lifecycle cancellation while libssh2 asks the caller
        // to wait and retry instead of completing the write.
        let bytes = Data("cancel-me".utf8)
        let driver = RecordingLibSSH2SessionDriver(
            sessionInitResult: OpaquePointer(bitPattern: 0x1),
            authMethods: .methods("publickey"),
            publicKeyAuthResult: .success,
            channelOpenResult: OpaquePointer(bitPattern: 0x22),
            channelWriteDelayMicroseconds: 5_000,
            channelWriteResults: Array(repeating: Int(LIBSSH2_ERROR_EAGAIN), count: 1_000)
        )
        let session = SSHSession(config: .libSSH2AuthLifecycleTest, driver: driver)

        // When the write task is cancelled while it is retrying EAGAIN.
        try await session.connect()
        let shell = try await session.startShell(cols: 80, rows: 24)
        let writeTask = Task {
            try await session.write(bytes, to: shell.id)
        }
        try await Task.sleep(for: .milliseconds(20))
        writeTask.cancel()

        // Then the write exits as cancellation, not as a later successful write
        // or a timeout caused by ignoring the cancellation request.
        do {
            try await SSHClient.runWithTimeout(.milliseconds(200)) {
                try await writeTask.value
            }
            XCTFail("Expected cancelled shell write to throw CancellationError")
        } catch is CancellationError {
            // Expected cancellation behavior.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }

        await session.closeShell(shell.id)
    }

    func testExecuteRetriesStartupEAGAINReadsStdoutAndClosesChannel() async throws {
        // Given an exec request whose process startup would block once, then
        // produces stdout and reaches EOF.
        let driver = RecordingLibSSH2SessionDriver(
            sessionInitResult: OpaquePointer(bitPattern: 0x1),
            authMethods: .methods("publickey"),
            publicKeyAuthResult: .success,
            channelOpenResult: OpaquePointer(bitPattern: 0x33),
            execStartResults: [
                Int32(LIBSSH2_ERROR_EAGAIN),
                0
            ],
            channelReadResults: [
                .data(Data("root\n".utf8)),
                .eagain
            ],
            channelEOFResults: [
                true
            ]
        )
        let session = SSHSession(config: .libSSH2AuthLifecycleTest, driver: driver)

        // When executing a command.
        try await session.connect()
        let output = try await SSHClient.runWithTimeout(
            .seconds(1),
            operation: {
                try await session.execute("whoami")
            },
            onTimeout: {
                session.abort()
            }
        )

        // Then startup retries, stdout is returned, and the exec channel is
        // closed through the same driver-owned teardown boundary.
        XCTAssertEqual(output, "root\n")
        XCTAssertEqual(
            driver.channelEvents(),
            [
                .openSession,
                .startExec("whoami"),
                .startExec("whoami"),
                .read(stream: 0),
                .read(stream: 1),
                .isEOF,
                .close,
                .free
            ],
            "Exec EAGAIN/read/EOF flow should stay observable at the driver boundary"
        )
    }

    func testExecUploadNonZeroExitDoesNotCloseFreedChannelTwice() async throws {
        // Given exec-preferred upload reaches remote process completion, frees
        // its channel, and then reports a non-zero exit status.
        let payload = Data("payload".utf8)
        let driver = RecordingLibSSH2SessionDriver(
            sessionInitResult: OpaquePointer(bitPattern: 0x1),
            authMethods: .methods("publickey"),
            publicKeyAuthResult: .success,
            channelOpenResult: OpaquePointer(bitPattern: 0x44),
            channelExitStatusResult: 7,
            channelReadResults: [
                .eagain,
                .eagain
            ],
            channelWriteResults: [
                payload.count
            ]
        )
        let session = SSHSession(config: .libSSH2AuthLifecycleTest, driver: driver)

        // When upload translates the non-zero exit status into an error.
        try await session.connect()
        do {
            try await session.upload(payload, to: "/tmp/vvterm-upload", strategy: SSHUploadStrategy.execPreferred)
            XCTFail("Expected non-zero exec upload exit status to fail")
        } catch SSHError.socketError(let message) {
            XCTAssertTrue(
                message.contains("exit status 7"),
                "Upload failure should preserve the remote exit status"
            )
        } catch {
            XCTFail("Expected SSHError.socketError for non-zero exit, got \(error)")
        }

        // Then the channel that finishUploadChannel already freed is not
        // closed/freed again by the outer upload catch path.
        let teardownEvents: [RecordingLibSSH2SessionDriver.ChannelEvent] = driver.channelEvents().filter { event in
            switch event {
            case .close, .free:
                return true
            default:
                return false
            }
        }
        let expectedTeardownEvents: [RecordingLibSSH2SessionDriver.ChannelEvent] = [.close, .free]
        XCTAssertEqual(
            teardownEvents,
            expectedTeardownEvents,
            "Exec upload must not close/free a channel after ownership was consumed by finishUploadChannel"
        )
    }

    func testExecUploadCloseFailurePreservesRawLibSSH2Error() async throws {
        // Given exec upload reaches channel close, but libssh2 reports a raw
        // close failure from the channel teardown boundary.
        let payload = Data("payload".utf8)
        let rawCloseError = LibSSH2RawError(
            operation: .channelClose,
            code: LIBSSH2_ERROR_SOCKET_SEND,
            message: "socket send failed while closing upload channel"
        )
        let driver = RecordingLibSSH2SessionDriver(
            sessionInitResult: OpaquePointer(bitPattern: 0x1),
            authMethods: .methods("publickey"),
            publicKeyAuthResult: .success,
            channelOpenResult: OpaquePointer(bitPattern: 0x44),
            channelCloseResult: rawCloseError.code,
            rawErrors: [rawCloseError],
            channelReadResults: [
                .eagain,
                .eagain
            ],
            channelWriteResults: [
                payload.count
            ]
        )
        let session = SSHSession(config: .libSSH2AuthLifecycleTest, driver: driver)

        // When upload channel close fails.
        try await session.connect()
        do {
            try await session.upload(payload, to: "/tmp/vvterm-upload", strategy: SSHUploadStrategy.execPreferred)
            XCTFail("Expected raw libssh2 channel close failure")
        } catch SSHError.libssh2(let rawError) {
            // Then the close failure remains distinguishable from a generic
            // socket error so teardown diagnostics preserve the C boundary.
            XCTAssertEqual(rawError.operation, .channelClose)
            XCTAssertEqual(rawError.code, LIBSSH2_ERROR_SOCKET_SEND)
            XCTAssertEqual(rawError.message, "socket send failed while closing upload channel")
        } catch {
            XCTFail("Expected SSHError.libssh2, got \(error)")
        }
    }

    func testExecUploadFreeFailureQueriesRawLibSSH2Error() async throws {
        // Given exec upload succeeds, but freeing the consumed upload channel
        // reports a non-retryable libssh2 teardown error.
        let payload = Data("payload".utf8)
        let rawFreeError = LibSSH2RawError(
            operation: .channelFree,
            code: LIBSSH2_ERROR_SOCKET_SEND,
            message: "socket send failed while freeing upload channel"
        )
        let driver = RecordingLibSSH2SessionDriver(
            sessionInitResult: OpaquePointer(bitPattern: 0x1),
            authMethods: .methods("publickey"),
            publicKeyAuthResult: .success,
            channelOpenResult: OpaquePointer(bitPattern: 0x44),
            channelFreeResult: rawFreeError.code,
            rawErrors: [rawFreeError],
            channelReadResults: [
                .eagain,
                .eagain
            ],
            channelWriteResults: [
                payload.count
            ]
        )
        let session = SSHSession(config: .libSSH2AuthLifecycleTest, driver: driver)

        // When upload completes and channel free reports a teardown diagnostic.
        try await session.connect()
        try await session.upload(payload, to: "/tmp/vvterm-upload", strategy: SSHUploadStrategy.execPreferred)

        // Then the free failure is still queried as a raw libssh2 error instead
        // of being silently discarded after the upload succeeds.
        XCTAssertTrue(
            driver.lastErrorOperations().contains(.channelFree),
            "Upload channel free failures must preserve raw teardown diagnostics"
        )
    }

    func testSFTPDirectoryReadFailureClosesHandleExactlyOnce() async throws {
        // Given SFTP can start and open a directory handle, but readdir fails
        // before any entry is returned.
        let driver = RecordingLibSSH2SessionDriver(
            sessionInitResult: OpaquePointer(bitPattern: 0x1),
            authMethods: .methods("publickey"),
            publicKeyAuthResult: .success,
            sftpSessionResult: OpaquePointer(bitPattern: 0x55),
            sftpOpenResult: OpaquePointer(bitPattern: 0x66),
            sftpReadDirectoryResults: [
                .error(Int(LIBSSH2_ERROR_SOCKET_RECV))
            ],
            sftpLastErrorResult: UInt(LIBSSH2_FX_CONNECTION_LOST)
        )
        let session = SSHSession(config: .libSSH2AuthLifecycleTest, driver: driver)

        // When directory listing maps the failed readdir to a RemoteFiles error.
        try await session.connect()
        do {
            _ = try await session.listDirectory(at: "/var/log")
            XCTFail("Expected SFTP read directory failure")
        } catch RemoteFileBrowserError.disconnected {
            // Then the SFTP error remains distinguishable for RemoteFiles.
        } catch {
            XCTFail("Expected RemoteFileBrowserError.disconnected, got \(error)")
        }

        // And the opened SFTP directory handle is closed exactly once.
        XCTAssertEqual(
            driver.sftpEvents(),
            [.initSession, .open(path: "/var/log"), .readDirectory, .closeHandle],
            "SFTP directory read failure must close the opened handle exactly once"
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

    enum ChannelEvent: Equatable {
        case openSession
        case setEnvironment(String)
        case requestPty
        case startShell
        case startExec(String)
        case read(stream: Int32)
        case write(stream: Int32, offset: Int, remaining: Int)
        case isEOF
        case close
        case free
    }

    enum ChannelReadResult {
        case data(Data)
        case eagain
        case error(Int)
    }

    enum SFTPEvent: Equatable {
        case initSession
        case shutdownSession
        case open(path: String)
        case readDirectory
        case closeHandle
    }

    enum SFTPReadDirectoryResult {
        case entry(String)
        case end
        case eagain
        case error(Int)
    }

    struct ChannelWriteCall: Equatable {
        let stream: Int32
        let bytes: [UInt8]
        let offset: Int
        let remaining: Int
    }

    private let sessionInitResult: OpaquePointer?
    private let connectedSocket: Int32
    private let handshakeBehavior: HandshakeBehavior
    private let authMethodsResult: AuthMethodsResult
    private let publicKeyAuthResult: AuthResult
    private let channelOpenResult: OpaquePointer?
    private let channelCloseResult: Int32
    private let channelFreeResult: Int32
    private let ptyResult: Int32
    private let shellStartResult: Int32
    private let execStartResult: Int32
    private let channelExitStatusResult: Int32
    private let sftpSessionResult: OpaquePointer?
    private let sftpOpenResult: OpaquePointer?
    private let sftpLastErrorResult: UInt
    private let sessionBlockDirectionsResult: Int32
    private let channelWriteDelayMicroseconds: useconds_t
    private let rawErrors: [LibSSH2RawError]
    private let lock = NSLock()
    private var closedSocketDescriptors: [Int32] = []
    private var observedSocketAbort = false
    private var channelEventLog: [ChannelEvent] = []
    private var sftpEventLog: [SFTPEvent] = []
    private var execStartResultQueue: [Int32]
    private var channelReadResultQueue: [ChannelReadResult]
    private var channelEOFResultQueue: [Bool]
    private var channelWriteResultQueue: [Int]
    private var sftpReadDirectoryResultQueue: [SFTPReadDirectoryResult]
    private var channelWriteCallLog: [ChannelWriteCall] = []
    private var lastErrorOperationLog: [LibSSH2RawError.Operation] = []
    private var keepAliveInvocationCount = 0

    init(
        sessionInitResult: OpaquePointer?,
        connectedSocket: Int32 = testSocket,
        handshakeBehavior: HandshakeBehavior = .succeed,
        authMethods: AuthMethodsResult = .unavailable,
        publicKeyAuthResult: AuthResult = .success,
        channelOpenResult: OpaquePointer? = nil,
        channelCloseResult: Int32 = 0,
        channelFreeResult: Int32 = 0,
        ptyResult: Int32 = 0,
        shellStartResult: Int32 = 0,
        execStartResult: Int32 = 0,
        channelExitStatusResult: Int32 = 0,
        sftpSessionResult: OpaquePointer? = nil,
        sftpOpenResult: OpaquePointer? = nil,
        sftpReadDirectoryResults: [SFTPReadDirectoryResult] = [],
        sftpLastErrorResult: UInt = 0,
        sessionBlockDirectionsResult: Int32 = 0,
        channelWriteDelayMicroseconds: useconds_t = 0,
        rawErrors: [LibSSH2RawError] = [],
        execStartResults: [Int32] = [],
        channelReadResults: [ChannelReadResult] = [],
        channelEOFResults: [Bool] = [],
        channelWriteResults: [Int] = []
    ) {
        self.sessionInitResult = sessionInitResult
        self.connectedSocket = connectedSocket
        self.handshakeBehavior = handshakeBehavior
        self.authMethodsResult = authMethods
        self.publicKeyAuthResult = publicKeyAuthResult
        self.channelOpenResult = channelOpenResult
        self.channelCloseResult = channelCloseResult
        self.channelFreeResult = channelFreeResult
        self.ptyResult = ptyResult
        self.shellStartResult = shellStartResult
        self.execStartResult = execStartResult
        self.channelExitStatusResult = channelExitStatusResult
        self.sftpSessionResult = sftpSessionResult
        self.sftpOpenResult = sftpOpenResult
        self.sftpLastErrorResult = sftpLastErrorResult
        self.sessionBlockDirectionsResult = sessionBlockDirectionsResult
        self.channelWriteDelayMicroseconds = channelWriteDelayMicroseconds
        self.rawErrors = rawErrors
        self.execStartResultQueue = execStartResults
        self.channelReadResultQueue = channelReadResults
        self.channelEOFResultQueue = channelEOFResults
        self.channelWriteResultQueue = channelWriteResults
        self.sftpReadDirectoryResultQueue = sftpReadDirectoryResults
    }

    func closedSockets() -> [Int32] {
        lock.lock()
        defer { lock.unlock() }
        return closedSocketDescriptors
    }

    func channelEvents(includeEnvironment: Bool = false) -> [ChannelEvent] {
        lock.lock()
        defer { lock.unlock() }
        guard includeEnvironment else {
            return channelEventLog.filter { event in
                if case .setEnvironment = event {
                    return false
                }
                return true
            }
        }
        return channelEventLog
    }

    func channelWriteCalls() -> [ChannelWriteCall] {
        lock.lock()
        defer { lock.unlock() }
        return channelWriteCallLog
    }

    func sftpEvents() -> [SFTPEvent] {
        lock.lock()
        defer { lock.unlock() }
        return sftpEventLog
    }

    func keepAliveCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return keepAliveInvocationCount
    }

    func lastErrorOperations() -> [LibSSH2RawError.Operation] {
        lock.lock()
        defer { lock.unlock() }
        return lastErrorOperationLog
    }

    private func recordChannelEvent(_ event: ChannelEvent) {
        lock.lock()
        defer { lock.unlock() }
        channelEventLog.append(event)
    }

    private func nextExecStartResult() -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        if execStartResultQueue.isEmpty {
            return execStartResult
        }
        return execStartResultQueue.removeFirst()
    }

    private func nextChannelReadResult() -> ChannelReadResult {
        lock.lock()
        defer { lock.unlock() }
        if channelReadResultQueue.isEmpty {
            return .eagain
        }
        return channelReadResultQueue.removeFirst()
    }

    private func nextChannelEOFResult() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if channelEOFResultQueue.isEmpty {
            return false
        }
        return channelEOFResultQueue.removeFirst()
    }

    private func nextChannelWriteResult(default defaultResult: Int) -> Int {
        lock.lock()
        defer { lock.unlock() }
        if channelWriteResultQueue.isEmpty {
            return defaultResult
        }
        return channelWriteResultQueue.removeFirst()
    }

    private func recordChannelWriteCall(_ call: ChannelWriteCall) {
        lock.lock()
        defer { lock.unlock() }
        channelWriteCallLog.append(call)
    }

    private func recordSFTPEvent(_ event: SFTPEvent) {
        lock.lock()
        defer { lock.unlock() }
        sftpEventLog.append(event)
    }

    private func nextSFTPReadDirectoryResult() -> SFTPReadDirectoryResult {
        lock.lock()
        defer { lock.unlock() }
        if sftpReadDirectoryResultQueue.isEmpty {
            return .end
        }
        return sftpReadDirectoryResultQueue.removeFirst()
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
        lock.lock()
        lastErrorOperationLog.append(operation)
        lock.unlock()

        if let rawError = rawErrors.first(where: { $0.operation == operation }) {
            return rawError
        }
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

    nonisolated func openSessionChannel(session: OpaquePointer) -> OpaquePointer? {
        recordChannelEvent(.openSession)
        return channelOpenResult
    }

    nonisolated func setChannelEnvironment(channel: OpaquePointer, name: String, value: String) -> Int32 {
        recordChannelEvent(.setEnvironment(name))
        return 0
    }

    nonisolated func requestPty(
        channel: OpaquePointer,
        terminalType: RemoteTerminalType,
        cols: Int,
        rows: Int
    ) -> Int32 {
        recordChannelEvent(.requestPty)
        return ptyResult
    }

    nonisolated func startShell(channel: OpaquePointer) -> Int32 {
        recordChannelEvent(.startShell)
        return shellStartResult
    }

    nonisolated func startExec(channel: OpaquePointer, command: String) -> Int32 {
        recordChannelEvent(.startExec(command))
        return nextExecStartResult()
    }

    nonisolated func closeChannel(_ channel: OpaquePointer) -> Int32 {
        recordChannelEvent(.close)
        return channelCloseResult
    }

    nonisolated func freeChannel(_ channel: OpaquePointer) -> Int32 {
        recordChannelEvent(.free)
        return channelFreeResult
    }

    nonisolated func readChannel(_ channel: OpaquePointer, stream: Int32, into buffer: inout [CChar]) -> Int {
        recordChannelEvent(.read(stream: stream))
        switch nextChannelReadResult() {
        case .data(let data):
            let bytes = [UInt8](data)
            let count = min(bytes.count, buffer.count)
            for index in 0..<count {
                buffer[index] = CChar(bitPattern: bytes[index])
            }
            return count
        case .eagain:
            return Int(LIBSSH2_ERROR_EAGAIN)
        case .error(let code):
            return code
        }
    }

    nonisolated func writeChannel(
        _ channel: OpaquePointer,
        stream: Int32,
        bytes: [UInt8],
        offset: Int,
        remaining: Int
    ) -> Int {
        if channelWriteDelayMicroseconds > 0 {
            usleep(channelWriteDelayMicroseconds)
        }
        recordChannelEvent(.write(stream: stream, offset: offset, remaining: remaining))
        recordChannelWriteCall(
            ChannelWriteCall(stream: stream, bytes: bytes, offset: offset, remaining: remaining)
        )
        return nextChannelWriteResult(default: remaining)
    }

    nonisolated func isChannelEOF(_ channel: OpaquePointer) -> Bool {
        recordChannelEvent(.isEOF)
        return nextChannelEOFResult()
    }

    nonisolated func sendChannelEOF(_ channel: OpaquePointer) -> Int32 {
        0
    }

    nonisolated func waitChannelEOF(_ channel: OpaquePointer) -> Int32 {
        0
    }

    nonisolated func waitChannelClosed(_ channel: OpaquePointer) -> Int32 {
        0
    }

    nonisolated func channelExitStatus(_ channel: OpaquePointer) -> Int32 {
        channelExitStatusResult
    }

    nonisolated func requestPtySize(channel: OpaquePointer, cols: Int, rows: Int) -> Int32 {
        0
    }

    nonisolated func handleExtendedData(channel: OpaquePointer, mode: Int32) -> Int32 {
        0
    }

    nonisolated func openSCPChannel(
        session: OpaquePointer,
        path: String,
        permissions: Int32,
        size: Int64
    ) -> OpaquePointer? {
        channelOpenResult
    }

    nonisolated func sessionBlockDirections(session: OpaquePointer) -> Int32 {
        sessionBlockDirectionsResult
    }

    nonisolated func initSFTPSession(session: OpaquePointer) -> OpaquePointer? {
        recordSFTPEvent(.initSession)
        return sftpSessionResult
    }

    nonisolated func shutdownSFTPSession(_ sftp: OpaquePointer) -> Int32 {
        recordSFTPEvent(.shutdownSession)
        return 0
    }

    nonisolated func openSFTPHandle(
        sftp: OpaquePointer,
        path: String,
        flags: UInt32,
        mode: Int32,
        openType: Int32
    ) -> OpaquePointer? {
        recordSFTPEvent(.open(path: path))
        return sftpOpenResult
    }

    nonisolated func closeSFTPHandle(_ handle: OpaquePointer) -> Int32 {
        recordSFTPEvent(.closeHandle)
        return 0
    }

    nonisolated func readSFTPDirectory(
        handle: OpaquePointer,
        into nameBuffer: inout [CChar],
        attributes: inout LIBSSH2_SFTP_ATTRIBUTES
    ) -> Int {
        recordSFTPEvent(.readDirectory)
        switch nextSFTPReadDirectoryResult() {
        case .entry(let name):
            let bytes = [UInt8](name.utf8)
            for index in 0..<min(bytes.count, nameBuffer.count) {
                nameBuffer[index] = CChar(bitPattern: bytes[index])
            }
            return min(bytes.count, nameBuffer.count)
        case .end:
            return 0
        case .eagain:
            return Int(LIBSSH2_ERROR_EAGAIN)
        case .error(let code):
            return code
        }
    }

    nonisolated func seekSFTPFile(handle: OpaquePointer, offset: UInt64) {}

    nonisolated func readSFTPFile(handle: OpaquePointer, into buffer: inout [CChar]) -> Int {
        0
    }

    nonisolated func writeSFTPFile(handle: OpaquePointer, data: Data, offset: Int, maxLength: Int) -> Int {
        maxLength
    }

    nonisolated func statSFTPPath(
        sftp: OpaquePointer,
        path: String,
        statType: Int32,
        attributes: inout LIBSSH2_SFTP_ATTRIBUTES
    ) -> Int32 {
        0
    }

    nonisolated func readSFTPSymlink(
        sftp: OpaquePointer,
        path: String,
        targetBuffer: inout [CChar],
        linkType: Int32
    ) -> Int {
        0
    }

    nonisolated func statSFTPFileSystem(
        sftp: OpaquePointer,
        path: String,
        status: inout LIBSSH2_SFTP_STATVFS
    ) -> Int32 {
        0
    }

    nonisolated func makeSFTPDirectory(sftp: OpaquePointer, path: String, permissions: Int32) -> Int {
        0
    }

    nonisolated func renameSFTPPath(
        sftp: OpaquePointer,
        sourcePath: String,
        destinationPath: String,
        flags: Int
    ) -> Int {
        0
    }

    nonisolated func unlinkSFTPFile(sftp: OpaquePointer, path: String) -> Int {
        0
    }

    nonisolated func removeSFTPDirectory(sftp: OpaquePointer, path: String) -> Int {
        0
    }

    nonisolated func lastSFTPError(_ sftp: OpaquePointer) -> UInt {
        sftpLastErrorResult
    }

    nonisolated func sendKeepAlive(session: OpaquePointer) -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        keepAliveInvocationCount += 1
        return 0
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
