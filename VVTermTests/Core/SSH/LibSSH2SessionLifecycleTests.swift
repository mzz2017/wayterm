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

    func testRuntimeInitializationStateRunsInitializerOnlyOnceAcrossConcurrentCallers() throws {
        let state = LibSSH2RuntimeInitializationState()
        let recorder = LibSSH2RuntimeInitializationRecorder()

        // Given libssh2 process initialization is a global FFI lifecycle step
        // that may be requested by multiple sessions at the same time.
        DispatchQueue.concurrentPerform(iterations: 32) { _ in
            try? state.ensureInitialized {
                recorder.recordInitialization()
            }
        }

        // Then the runtime owner serializes callers and invokes libssh2_init
        // once, keeping the process-global C runtime alive for the app lifetime.
        XCTAssertEqual(
            recorder.initializationCount,
            1,
            "libssh2 runtime initialization must run exactly once across concurrent session starts"
        )
    }

    func testRuntimeInitializationStateRetriesAfterInitializationFailure() throws {
        let state = LibSSH2RuntimeInitializationState()
        let recorder = LibSSH2RuntimeInitializationRecorder()

        // Given the first libssh2_init attempt fails before the C runtime is
        // ready for use.
        XCTAssertThrowsError(
            try state.ensureInitialized {
                recorder.recordInitialization()
                throw SSHError.unknown("libssh2_init failed: -1")
            }
        )

        // When a later session attempts initialization again.
        try state.ensureInitialized {
            recorder.recordInitialization()
        }

        // Then failure is not cached as success; the owner retries once and
        // records the successful process-global initialization.
        XCTAssertEqual(
            recorder.initializationCount,
            2,
            "Failed libssh2 initialization must not mark the runtime as initialized"
        )
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

    func testKeyboardInteractiveAuthUsesSessionOwnedContext() async throws {
        // Given a server that falls back from password auth to
        // keyboard-interactive prompts.
        let driver = RecordingLibSSH2SessionDriver(
            sessionInitResult: OpaquePointer(bitPattern: 0x1),
            authMethods: .methods("password,keyboard-interactive")
        )
        let session = SSHSession(config: .libSSH2KeyboardInteractiveAuthTest, driver: driver)

        // When libssh2 asks the callback for an interactive response.
        try await session.connect()

        // Then the callback reads password state from the actor-owned session
        // abstract context, not from a temporary stack pointer.
        XCTAssertTrue(
            driver.sessionAbstractWasProvided(),
            "SSHSession should provide a stable actor-owned context as libssh2 session abstract data."
        )
        XCTAssertEqual(
            driver.keyboardInteractiveResponses(),
            ["keyboard-secret"],
            "Keyboard-interactive auth should read the password through the session-owned abstract context."
        )
    }

    func testKeyboardInteractiveCallbackLeavesResponsesEmptyWithoutContext() {
        var abstract: UnsafeMutableRawPointer?
        var response = LIBSSH2_USERAUTH_KBDINT_RESPONSE(text: nil, length: 0)

        // Given libssh2 invokes the callback without the session-owned abstract
        // context that carries the keyboard-interactive password.
        withUnsafeMutablePointer(to: &abstract) { abstractPointer in
            withUnsafeMutablePointer(to: &response) { responsePointer in
                KeyboardInteractiveCallbackOwner.respond(
                    nil,
                    0,
                    nil,
                    0,
                    1,
                    nil,
                    responsePointer,
                    abstractPointer
                )
            }
        }

        // Then the callback does not allocate or publish a response, avoiding
        // stale credential reuse across auth sessions.
        XCTAssertNil(response.text)
        XCTAssertEqual(response.length, 0)
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

    func testExecuteChannelOpenFailurePreservesRawLibSSH2Error() async throws {
        // Given an exec request whose channel open fails for a concrete libssh2
        // transport reason instead of ordinary EAGAIN retry pressure.
        let rawOpenError = LibSSH2RawError(
            operation: .channelOpen,
            code: LIBSSH2_ERROR_SOCKET_RECV,
            message: "socket recv failed while opening exec channel"
        )
        let driver = RecordingLibSSH2SessionDriver(
            sessionInitResult: OpaquePointer(bitPattern: 0x1),
            authMethods: .methods("publickey"),
            publicKeyAuthResult: .success,
            channelOpenResult: nil,
            rawErrors: [rawOpenError]
        )
        let session = SSHSession(config: .libSSH2AuthLifecycleTest, driver: driver)

        // When command execution attempts to open its channel.
        try await session.connect()
        do {
            _ = try await SSHClient.runWithTimeout(.seconds(1)) {
                try await session.execute("whoami")
            }
            XCTFail("Expected raw libssh2 exec channel-open failure")
        } catch SSHError.libssh2(let rawError) {
            // Then the C-boundary operation, code, and message survive
            // translation for diagnostics instead of collapsing to a generic
            // channel-open error.
            XCTAssertEqual(rawError.operation, .channelOpen)
            XCTAssertEqual(rawError.code, LIBSSH2_ERROR_SOCKET_RECV)
            XCTAssertEqual(rawError.message, "socket recv failed while opening exec channel")
        } catch {
            XCTFail("Expected SSHError.libssh2, got \(error)")
        }
    }

    func testExecuteStartupFailurePreservesRawLibSSH2Error() async throws {
        // Given an exec request whose process startup fails after the channel
        // was opened successfully.
        let rawStartupError = LibSSH2RawError(
            operation: .channelProcessStartup,
            code: LIBSSH2_ERROR_CHANNEL_REQUEST_DENIED,
            message: "exec request denied by server"
        )
        let driver = RecordingLibSSH2SessionDriver(
            sessionInitResult: OpaquePointer(bitPattern: 0x1),
            authMethods: .methods("publickey"),
            publicKeyAuthResult: .success,
            channelOpenResult: OpaquePointer(bitPattern: 0x33),
            execStartResult: rawStartupError.code,
            rawErrors: [rawStartupError]
        )
        let session = SSHSession(config: .libSSH2AuthLifecycleTest, driver: driver)

        // When command execution starts the remote exec process.
        try await session.connect()
        do {
            _ = try await SSHClient.runWithTimeout(.seconds(1)) {
                try await session.execute("whoami")
            }
            XCTFail("Expected raw libssh2 exec startup failure")
        } catch SSHError.libssh2(let rawError) {
            // Then startup remains distinguishable from command stderr,
            // channel-open failure, and generic unknown errors.
            XCTAssertEqual(rawError.operation, .channelProcessStartup)
            XCTAssertEqual(rawError.code, LIBSSH2_ERROR_CHANNEL_REQUEST_DENIED)
            XCTAssertEqual(rawError.message, "exec request denied by server")
        } catch {
            XCTFail("Expected SSHError.libssh2, got \(error)")
        }
    }

    func testShellAndExecCleanupTasksAreTrackedBySessionOwner() throws {
        // Given the SSHSession implementation that owns libssh2 shell and exec
        // channels.
        let source = try sshSessionSource()
        let channelsSource = try sshSessionChannelsSource()
        let registrySource = try sshChannelCleanupTaskRegistrySource()
        let sessionSource = try slice(
            startingAt: "actor SSHSession {",
            endingBefore: "    // MARK: - Keep Alive",
            in: source
        )
        let startShellSource = try slice(
            startingAt: "    func startShell(",
            endingBefore: "    func startIOLoop()",
            in: channelsSource
        )
        let executeSource = try slice(
            startingAt: "    func execute(_ command: String) async throws -> String",
            endingBefore: "\n}\n",
            in: channelsSource
        )
        let disconnectSource = try slice(
            startingAt: "    func disconnect() async {",
            endingBefore: "    private func cleanupLibssh2()",
            in: sessionSource
        )

        // Then lifecycle-critical shell stream termination and exec
        // cancellation cleanup must be routed through a session-owned tracker
        // rather than untracked fire-and-forget tasks.
        XCTAssertTrue(
            registrySource.contains("final class SSHChannelCleanupTaskRegistry"),
            "SSHSession should own a channel cleanup task registry."
        )
        XCTAssertTrue(
            registrySource.contains("Task.detached"),
            "The cleanup registry should track asynchronous cleanup tasks created from synchronous callbacks."
        )
        XCTAssertTrue(
            startShellSource.contains("trackChannelCleanupTask"),
            "Shell stream termination should register its close/free cleanup task with SSHSession."
        )
        XCTAssertFalse(
            startShellSource.contains("\n                Task { [weak self] in\n                    await self?.closeShell(shellId)"),
            "Shell stream termination must not launch an untracked closeShell task."
        )
        XCTAssertFalse(
            startShellSource.contains("await self?.closeShell(shellId)"),
            "Shell stream termination must not drop closeShell cleanup through a nil weak capture."
        )
        XCTAssertTrue(
            executeSource.contains("trackChannelCleanupTask"),
            "Exec cancellation should register its channel cleanup task with SSHSession."
        )
        XCTAssertFalse(
            executeSource.contains("Task {\n                await self?.cancelExecRequest"),
            "Exec cancellation must not launch an untracked cancelExecRequest task."
        )
        XCTAssertFalse(
            executeSource.contains("self?.trackChannelCleanupTask"),
            "Exec cancellation should retain the SSHSession owner while registering critical cleanup."
        )
        XCTAssertTrue(
            disconnectSource.contains("await waitForChannelCleanupTasks()"),
            "SSHSession.disconnect should await tracked channel cleanup before final libssh2 cleanup completes."
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

    func testExecUploadChannelOpenFailurePreservesRawLibSSH2Error() async throws {
        // Given exec-preferred upload cannot open its channel and libssh2 has a
        // concrete raw diagnostic for the failure.
        let payload = Data("payload".utf8)
        let rawOpenError = LibSSH2RawError(
            operation: .channelOpen,
            code: LIBSSH2_ERROR_SOCKET_RECV,
            message: "socket recv failed while opening upload channel"
        )
        let driver = RecordingLibSSH2SessionDriver(
            sessionInitResult: OpaquePointer(bitPattern: 0x1),
            authMethods: .methods("publickey"),
            publicKeyAuthResult: .success,
            channelOpenResult: nil,
            rawErrors: [rawOpenError]
        )
        let session = SSHSession(config: .libSSH2AuthLifecycleTest, driver: driver)

        // When upload attempts to open the exec channel.
        try await session.connect()
        do {
            try await session.upload(payload, to: "/tmp/vvterm-upload", strategy: SSHUploadStrategy.execPreferred)
            XCTFail("Expected raw libssh2 exec upload channel-open failure")
        } catch SSHError.libssh2(let rawError) {
            // Then upload channel-open diagnostics preserve the raw C-boundary
            // operation rather than only exposing a formatted socket string.
            XCTAssertEqual(rawError.operation, .channelOpen)
            XCTAssertEqual(rawError.code, LIBSSH2_ERROR_SOCKET_RECV)
            XCTAssertEqual(rawError.message, "socket recv failed while opening upload channel")
        } catch {
            XCTFail("Expected SSHError.libssh2, got \(error)")
        }
    }

    func testSCPUploadChannelOpenFailurePreservesRawLibSSH2Error() async throws {
        // Given SCP upload cannot open its channel and libssh2 exposes a raw
        // diagnostic for the channel-open operation.
        let payload = Data("payload".utf8)
        let rawOpenError = LibSSH2RawError(
            operation: .scpChannelOpen,
            code: LIBSSH2_ERROR_SOCKET_RECV,
            message: "socket recv failed while opening scp upload channel"
        )
        let driver = RecordingLibSSH2SessionDriver(
            sessionInitResult: OpaquePointer(bitPattern: 0x1),
            authMethods: .methods("publickey"),
            publicKeyAuthResult: .success,
            channelOpenResult: nil,
            rawErrors: [rawOpenError]
        )
        let session = SSHSession(config: .libSSH2AuthLifecycleTest, driver: driver)

        // When SCP upload is selected directly for a regression-level error
        // check.
        try await session.connect()
        do {
            try await session.upload(payload, to: "/tmp/vvterm-upload", strategy: SSHUploadStrategy.scpOnly)
            XCTFail("Expected raw libssh2 SCP upload channel-open failure")
        } catch SSHError.libssh2(let rawError) {
            // Then the SCP-specific raw operation, code, and message survive
            // translation instead of being collapsed into a string code.
            XCTAssertEqual(rawError.operation, .scpChannelOpen)
            XCTAssertEqual(rawError.code, LIBSSH2_ERROR_SOCKET_RECV)
            XCTAssertEqual(rawError.message, "socket recv failed while opening scp upload channel")
        } catch {
            XCTFail("Expected SSHError.libssh2, got \(error)")
        }
    }

    func testSCPUploadWriteFailurePreservesRawLibSSH2Error() async throws {
        // Given SCP upload opens its channel but libssh2 fails while writing the
        // payload.
        let payload = Data("payload".utf8)
        let rawWriteError = LibSSH2RawError(
            operation: .channelWrite,
            code: LIBSSH2_ERROR_SOCKET_SEND,
            message: "socket send failed while writing scp upload payload"
        )
        let driver = RecordingLibSSH2SessionDriver(
            sessionInitResult: OpaquePointer(bitPattern: 0x1),
            authMethods: .methods("publickey"),
            publicKeyAuthResult: .success,
            channelOpenResult: OpaquePointer(bitPattern: 0x44),
            rawErrors: [rawWriteError],
            channelWriteResults: [
                Int(rawWriteError.code)
            ]
        )
        let session = SSHSession(config: .libSSH2AuthLifecycleTest, driver: driver)

        // When SCP upload writes the payload.
        try await session.connect()
        do {
            try await session.upload(payload, to: "/tmp/vvterm-upload", strategy: SSHUploadStrategy.scpOnly)
            XCTFail("Expected raw libssh2 SCP upload write failure")
        } catch SSHError.libssh2(let rawError) {
            // Then payload write diagnostics keep the raw channel-write
            // operation instead of becoming a generic socket error string.
            XCTAssertEqual(rawError.operation, .channelWrite)
            XCTAssertEqual(rawError.code, LIBSSH2_ERROR_SOCKET_SEND)
            XCTAssertEqual(rawError.message, "socket send failed while writing scp upload payload")
        } catch {
            XCTFail("Expected SSHError.libssh2, got \(error)")
        }
    }

    func testExecUploadStartupFailurePreservesRawLibSSH2Error() async throws {
        // Given exec-preferred upload opens a channel but the remote `cat`
        // startup request fails with a libssh2 diagnostic.
        let payload = Data("payload".utf8)
        let rawStartupError = LibSSH2RawError(
            operation: .channelProcessStartup,
            code: LIBSSH2_ERROR_CHANNEL_REQUEST_DENIED,
            message: "upload exec request denied by server"
        )
        let driver = RecordingLibSSH2SessionDriver(
            sessionInitResult: OpaquePointer(bitPattern: 0x1),
            authMethods: .methods("publickey"),
            publicKeyAuthResult: .success,
            channelOpenResult: OpaquePointer(bitPattern: 0x44),
            execStartResult: rawStartupError.code,
            rawErrors: [rawStartupError]
        )
        let session = SSHSession(config: .libSSH2AuthLifecycleTest, driver: driver)

        // When upload starts its remote exec process.
        try await session.connect()
        do {
            try await session.upload(payload, to: "/tmp/vvterm-upload", strategy: SSHUploadStrategy.execPreferred)
            XCTFail("Expected raw libssh2 exec upload startup failure")
        } catch SSHError.libssh2(let rawError) {
            // Then the startup failure remains distinguishable from later data
            // write, close, and wait-closed failures.
            XCTAssertEqual(rawError.operation, .channelProcessStartup)
            XCTAssertEqual(rawError.code, LIBSSH2_ERROR_CHANNEL_REQUEST_DENIED)
            XCTAssertEqual(rawError.message, "upload exec request denied by server")
        } catch {
            XCTFail("Expected SSHError.libssh2, got \(error)")
        }
    }

    func testExecUploadWriteFailurePreservesRawLibSSH2Error() async throws {
        // Given exec-preferred upload starts successfully, but writing payload
        // bytes fails for a raw libssh2 transport reason.
        let payload = Data("payload".utf8)
        let rawWriteError = LibSSH2RawError(
            operation: .channelWrite,
            code: LIBSSH2_ERROR_SOCKET_SEND,
            message: "socket send failed while writing upload payload"
        )
        let driver = RecordingLibSSH2SessionDriver(
            sessionInitResult: OpaquePointer(bitPattern: 0x1),
            authMethods: .methods("publickey"),
            publicKeyAuthResult: .success,
            channelOpenResult: OpaquePointer(bitPattern: 0x44),
            rawErrors: [rawWriteError],
            channelWriteResults: [
                Int(rawWriteError.code)
            ]
        )
        let session = SSHSession(config: .libSSH2AuthLifecycleTest, driver: driver)

        // When upload writes the payload.
        try await session.connect()
        do {
            try await session.upload(payload, to: "/tmp/vvterm-upload", strategy: SSHUploadStrategy.execPreferred)
            XCTFail("Expected raw libssh2 exec upload write failure")
        } catch SSHError.libssh2(let rawError) {
            // Then payload write diagnostics keep the raw channel-write
            // operation instead of becoming a generic socket error string.
            XCTAssertEqual(rawError.operation, .channelWrite)
            XCTAssertEqual(rawError.code, LIBSSH2_ERROR_SOCKET_SEND)
            XCTAssertEqual(rawError.message, "socket send failed while writing upload payload")
        } catch {
            XCTFail("Expected SSHError.libssh2, got \(error)")
        }
    }

    func testExecUploadStdoutDrainFailurePreservesRawLibSSH2Error() async throws {
        // Given exec-preferred upload writes all data, but draining remote
        // stdout fails with a raw libssh2 read diagnostic.
        let payload = Data("payload".utf8)
        let rawReadError = LibSSH2RawError(
            operation: .channelRead,
            code: LIBSSH2_ERROR_SOCKET_RECV,
            message: "socket recv failed while draining upload stdout"
        )
        let driver = RecordingLibSSH2SessionDriver(
            sessionInitResult: OpaquePointer(bitPattern: 0x1),
            authMethods: .methods("publickey"),
            publicKeyAuthResult: .success,
            channelOpenResult: OpaquePointer(bitPattern: 0x44),
            rawErrors: [rawReadError],
            channelReadResults: [
                .error(Int(rawReadError.code))
            ],
            channelWriteResults: [
                payload.count
            ]
        )
        let session = SSHSession(config: .libSSH2AuthLifecycleTest, driver: driver)

        // When upload drains remote stdout during channel teardown.
        try await session.connect()
        do {
            try await session.upload(payload, to: "/tmp/vvterm-upload", strategy: SSHUploadStrategy.execPreferred)
            XCTFail("Expected raw libssh2 exec upload stdout drain failure")
        } catch SSHError.libssh2(let rawError) {
            // Then read diagnostics keep their raw operation and message instead
            // of collapsing to a formatted socket string.
            XCTAssertEqual(rawError.operation, .channelRead)
            XCTAssertEqual(rawError.code, LIBSSH2_ERROR_SOCKET_RECV)
            XCTAssertEqual(rawError.message, "socket recv failed while draining upload stdout")
        } catch {
            XCTFail("Expected SSHError.libssh2, got \(error)")
        }
    }

    func testExecUploadStderrDrainFailurePreservesRawLibSSH2Error() async throws {
        // Given exec-preferred upload drains stdout successfully, but draining
        // remote stderr fails with a raw libssh2 read diagnostic.
        let payload = Data("payload".utf8)
        let rawReadError = LibSSH2RawError(
            operation: .channelRead,
            code: LIBSSH2_ERROR_SOCKET_RECV,
            message: "socket recv failed while draining upload stderr"
        )
        let driver = RecordingLibSSH2SessionDriver(
            sessionInitResult: OpaquePointer(bitPattern: 0x1),
            authMethods: .methods("publickey"),
            publicKeyAuthResult: .success,
            channelOpenResult: OpaquePointer(bitPattern: 0x44),
            rawErrors: [rawReadError],
            channelReadResults: [
                .eagain,
                .error(Int(rawReadError.code))
            ],
            channelWriteResults: [
                payload.count
            ]
        )
        let session = SSHSession(config: .libSSH2AuthLifecycleTest, driver: driver)

        // When upload drains remote stderr during channel teardown.
        try await session.connect()
        do {
            try await session.upload(payload, to: "/tmp/vvterm-upload", strategy: SSHUploadStrategy.execPreferred)
            XCTFail("Expected raw libssh2 exec upload stderr drain failure")
        } catch SSHError.libssh2(let rawError) {
            // Then read diagnostics keep their raw operation and message instead
            // of collapsing to a formatted socket string.
            XCTAssertEqual(rawError.operation, .channelRead)
            XCTAssertEqual(rawError.code, LIBSSH2_ERROR_SOCKET_RECV)
            XCTAssertEqual(rawError.message, "socket recv failed while draining upload stderr")
        } catch {
            XCTFail("Expected SSHError.libssh2, got \(error)")
        }
    }

    func testExecUploadSendEOFFailurePreservesRawLibSSH2Error() async throws {
        // Given exec-preferred upload writes all data, but sending channel EOF
        // fails with a raw libssh2 teardown diagnostic.
        let payload = Data("payload".utf8)
        let rawEOFError = LibSSH2RawError(
            operation: .channelEOF,
            code: LIBSSH2_ERROR_SOCKET_SEND,
            message: "socket send failed while sending upload EOF"
        )
        let driver = RecordingLibSSH2SessionDriver(
            sessionInitResult: OpaquePointer(bitPattern: 0x1),
            authMethods: .methods("publickey"),
            publicKeyAuthResult: .success,
            channelOpenResult: OpaquePointer(bitPattern: 0x44),
            channelSendEOFResult: rawEOFError.code,
            rawErrors: [rawEOFError],
            channelWriteResults: [
                payload.count
            ]
        )
        let session = SSHSession(config: .libSSH2AuthLifecycleTest, driver: driver)

        // When upload finishes writing and starts channel teardown.
        try await session.connect()
        do {
            try await session.upload(payload, to: "/tmp/vvterm-upload", strategy: SSHUploadStrategy.execPreferred)
            XCTFail("Expected raw libssh2 exec upload EOF failure")
        } catch SSHError.libssh2(let rawError) {
            // Then EOF send diagnostics keep their raw operation and message.
            XCTAssertEqual(rawError.operation, .channelEOF)
            XCTAssertEqual(rawError.code, LIBSSH2_ERROR_SOCKET_SEND)
            XCTAssertEqual(rawError.message, "socket send failed while sending upload EOF")
        } catch {
            XCTFail("Expected SSHError.libssh2, got \(error)")
        }
    }

    func testExecUploadWaitEOFFailurePreservesRawLibSSH2Error() async throws {
        // Given exec-preferred upload sends EOF successfully, but waiting for
        // remote EOF fails with a raw libssh2 diagnostic.
        let payload = Data("payload".utf8)
        let rawWaitEOFError = LibSSH2RawError(
            operation: .channelWaitEOF,
            code: LIBSSH2_ERROR_SOCKET_RECV,
            message: "socket recv failed while waiting for upload EOF"
        )
        let driver = RecordingLibSSH2SessionDriver(
            sessionInitResult: OpaquePointer(bitPattern: 0x1),
            authMethods: .methods("publickey"),
            publicKeyAuthResult: .success,
            channelOpenResult: OpaquePointer(bitPattern: 0x44),
            channelWaitEOFResult: rawWaitEOFError.code,
            rawErrors: [rawWaitEOFError],
            channelReadResults: [
                .eagain,
                .eagain
            ],
            channelWriteResults: [
                payload.count
            ]
        )
        let session = SSHSession(config: .libSSH2AuthLifecycleTest, driver: driver)

        // When upload waits for remote EOF during channel teardown.
        try await session.connect()
        do {
            try await session.upload(payload, to: "/tmp/vvterm-upload", strategy: SSHUploadStrategy.execPreferred)
            XCTFail("Expected raw libssh2 exec upload wait-EOF failure")
        } catch SSHError.libssh2(let rawError) {
            // Then wait-EOF diagnostics stay separate from close and
            // wait-closed failures.
            XCTAssertEqual(rawError.operation, .channelWaitEOF)
            XCTAssertEqual(rawError.code, LIBSSH2_ERROR_SOCKET_RECV)
            XCTAssertEqual(rawError.message, "socket recv failed while waiting for upload EOF")
        } catch {
            XCTFail("Expected SSHError.libssh2, got \(error)")
        }
    }

    func testExecUploadWaitClosedFailurePreservesRawLibSSH2Error() async throws {
        // Given exec-preferred upload finishes data transfer and close succeeds,
        // but libssh2 reports a raw error while waiting for close completion.
        let payload = Data("payload".utf8)
        let rawWaitClosedError = LibSSH2RawError(
            operation: .channelWaitClosed,
            code: LIBSSH2_ERROR_SOCKET_RECV,
            message: "socket recv failed while waiting for upload close"
        )
        let driver = RecordingLibSSH2SessionDriver(
            sessionInitResult: OpaquePointer(bitPattern: 0x1),
            authMethods: .methods("publickey"),
            publicKeyAuthResult: .success,
            channelOpenResult: OpaquePointer(bitPattern: 0x44),
            channelWaitClosedResult: rawWaitClosedError.code,
            rawErrors: [rawWaitClosedError],
            channelReadResults: [
                .eagain,
                .eagain
            ],
            channelWriteResults: [
                payload.count
            ]
        )
        let session = SSHSession(config: .libSSH2AuthLifecycleTest, driver: driver)

        // When upload waits for the remote channel to report closed.
        try await session.connect()
        do {
            try await session.upload(payload, to: "/tmp/vvterm-upload", strategy: SSHUploadStrategy.execPreferred)
            XCTFail("Expected raw libssh2 exec upload wait-closed failure")
        } catch SSHError.libssh2(let rawError) {
            // Then wait-closed diagnostics are preserved separately from the
            // preceding successful channel close.
            XCTAssertEqual(rawError.operation, .channelWaitClosed)
            XCTAssertEqual(rawError.code, LIBSSH2_ERROR_SOCKET_RECV)
            XCTAssertEqual(rawError.message, "socket recv failed while waiting for upload close")
        } catch {
            XCTFail("Expected SSHError.libssh2, got \(error)")
        }
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

        // When directory listing maps the failed readdir to a Core SSH transfer error.
        try await session.connect()
        do {
            _ = try await session.listDirectory(at: "/var/log")
            XCTFail("Expected SFTP read directory failure")
        } catch SSHFileTransferError.disconnected {
            // Then the SFTP error remains distinguishable for RemoteFiles adapters.
        } catch {
            XCTFail("Expected SSHFileTransferError.disconnected, got \(error)")
        }

        // And the opened SFTP directory handle is closed exactly once.
        XCTAssertEqual(
            driver.sftpEvents(),
            [.initSession, .open(path: "/var/log"), .readDirectory, .closeHandle],
            "SFTP directory read failure must close the opened handle exactly once"
        )
    }

    private func sshSessionSource() throws -> String {
        try String(
            contentsOf: sourceRoot().appendingPathComponent("VVTerm/Core/SSH/SSHSession.swift"),
            encoding: .utf8
        )
    }

    private func sshSessionChannelsSource() throws -> String {
        try String(
            contentsOf: sourceRoot().appendingPathComponent("VVTerm/Core/SSH/SSHSession+Channels.swift"),
            encoding: .utf8
        )
    }

    private func sshChannelCleanupTaskRegistrySource() throws -> String {
        try String(
            contentsOf: sourceRoot().appendingPathComponent("VVTerm/Core/SSH/SSHChannelCleanupTaskRegistry.swift"),
            encoding: .utf8
        )
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

    private func slice(startingAt marker: String, endingBefore endMarker: String, in source: String) throws -> String {
        guard let start = source.range(of: marker),
              let end = source.range(of: endMarker, range: start.lowerBound..<source.endIndex)
        else {
            throw SourceSliceError.notFound
        }
        return String(source[start.lowerBound..<end.lowerBound])
    }
}

private final class LibSSH2RuntimeInitializationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var initializationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func recordInitialization() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}

private enum SourceRootError: Error {
    case notFound
}

private enum SourceSliceError: Error {
    case notFound
}
