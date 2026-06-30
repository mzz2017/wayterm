import Darwin
import Foundation
@testable import VVTerm

// Test support for libssh2 lifecycle suites. Keep this fake driver behavior-focused;
// individual suite files own the product invariants they assert.

extension SSHSessionConfig {
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

    static var libSSH2KeyboardInteractiveAuthTest: SSHSessionConfig {
        let serverId = UUID(uuidString: "00000000-0000-0000-0000-000000000012")!
        return SSHSessionConfig(
            host: "ssh.example.com",
            port: 22,
            dialHost: "ssh.example.com",
            dialPort: 22,
            hostKeyHost: "ssh.example.com",
            hostKeyPort: 22,
            username: "root",
            connectionMode: .standard,
            authMethod: .password,
            credentials: ServerCredentials(
                serverId: serverId,
                password: "keyboard-secret",
                privateKey: nil,
                publicKey: nil,
                passphrase: nil,
                cloudflareClientID: nil,
                cloudflareClientSecret: nil
            )
        )
    }
}

final class RecordingLibSSH2SessionDriver: @unchecked Sendable, LibSSH2SessionDriving {
    static let testSocket: Int32 = 42

    enum HandshakeBehavior {
        case succeed
        case waitForSocketClose
    }

    enum ConnectSocketBehavior {
        case succeed
        case timeout
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

    struct KeyboardInteractiveResponseBuffer: Equatable {
        let text: String
        let reportedLength: UInt32
        let terminator: CChar
    }

    private let sessionInitResult: OpaquePointer?
    private let connectedSocket: Int32
    private let connectSocketBehavior: ConnectSocketBehavior
    private let handshakeBehavior: HandshakeBehavior
    private let authMethodsResult: AuthMethodsResult
    private let publicKeyAuthResult: AuthResult
    private let channelOpenResult: OpaquePointer?
    private let channelCloseResult: Int32
    private let channelFreeResult: Int32
    private let channelSendEOFResult: Int32
    private let channelWaitEOFResult: Int32
    private let channelWaitClosedResult: Int32
    private let ptyResult: Int32
    private let shellStartResult: Int32
    private let execStartResult: Int32
    private let channelExitStatusResult: Int32
    private let sftpSessionResult: OpaquePointer?
    private let sftpOpenResult: OpaquePointer?
    private let sftpLastErrorResult: UInt
    private let sessionBlockDirectionsResult: Int32
    private let channelWriteDelayMicroseconds: useconds_t
    private let shouldBlockDisconnect: Bool
    private let rawErrors: [LibSSH2RawError]
    private let lock = NSLock()
    private var closedSocketDescriptors: [Int32] = []
    private var observedSocketAbort = false
    private var disconnectInvocationCount = 0
    private let disconnectReleaseSemaphore = DispatchSemaphore(value: 0)
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
    private var sessionAbstractPointer: UnsafeMutableRawPointer?
    private var keyboardInteractiveResponseLog: [String] = []
    private var keyboardInteractiveResponseBufferLog: [KeyboardInteractiveResponseBuffer] = []
    private var connectSocketTimeoutLog: [TimeInterval] = []

    init(
        sessionInitResult: OpaquePointer?,
        connectedSocket: Int32 = testSocket,
        connectSocketBehavior: ConnectSocketBehavior = .succeed,
        handshakeBehavior: HandshakeBehavior = .succeed,
        authMethods: AuthMethodsResult = .unavailable,
        publicKeyAuthResult: AuthResult = .success,
        channelOpenResult: OpaquePointer? = nil,
        channelCloseResult: Int32 = 0,
        channelFreeResult: Int32 = 0,
        channelSendEOFResult: Int32 = 0,
        channelWaitEOFResult: Int32 = 0,
        channelWaitClosedResult: Int32 = 0,
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
        shouldBlockDisconnect: Bool = false,
        rawErrors: [LibSSH2RawError] = [],
        execStartResults: [Int32] = [],
        channelReadResults: [ChannelReadResult] = [],
        channelEOFResults: [Bool] = [],
        channelWriteResults: [Int] = []
    ) {
        self.sessionInitResult = sessionInitResult
        self.connectedSocket = connectedSocket
        self.connectSocketBehavior = connectSocketBehavior
        self.handshakeBehavior = handshakeBehavior
        self.authMethodsResult = authMethods
        self.publicKeyAuthResult = publicKeyAuthResult
        self.channelOpenResult = channelOpenResult
        self.channelCloseResult = channelCloseResult
        self.channelFreeResult = channelFreeResult
        self.channelSendEOFResult = channelSendEOFResult
        self.channelWaitEOFResult = channelWaitEOFResult
        self.channelWaitClosedResult = channelWaitClosedResult
        self.ptyResult = ptyResult
        self.shellStartResult = shellStartResult
        self.execStartResult = execStartResult
        self.channelExitStatusResult = channelExitStatusResult
        self.sftpSessionResult = sftpSessionResult
        self.sftpOpenResult = sftpOpenResult
        self.sftpLastErrorResult = sftpLastErrorResult
        self.sessionBlockDirectionsResult = sessionBlockDirectionsResult
        self.channelWriteDelayMicroseconds = channelWriteDelayMicroseconds
        self.shouldBlockDisconnect = shouldBlockDisconnect
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

    func connectSocketTimeouts() -> [TimeInterval] {
        lock.lock()
        defer { lock.unlock() }
        return connectSocketTimeoutLog
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

    func disconnectCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return disconnectInvocationCount
    }

    func releaseDisconnect() {
        disconnectReleaseSemaphore.signal()
    }

    func sessionAbstractWasProvided() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return sessionAbstractPointer != nil
    }

    func keyboardInteractiveResponses() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return keyboardInteractiveResponseLog
    }

    func keyboardInteractiveResponseBuffers() -> [KeyboardInteractiveResponseBuffer] {
        lock.lock()
        defer { lock.unlock() }
        return keyboardInteractiveResponseBufferLog
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

    nonisolated func connectSocket(host: String, port: Int, timeout: TimeInterval) throws -> LibSSH2ConnectedSocket {
        lock.lock()
        connectSocketTimeoutLog.append(timeout)
        lock.unlock()

        if connectSocketBehavior == .timeout {
            Thread.sleep(forTimeInterval: timeout)
            throw SSHError.timeout
        }

        return LibSSH2ConnectedSocket(descriptor: connectedSocket, peerAddress: "203.0.113.10")
    }

    nonisolated func configureInteractiveSocket(_ socket: Int32) {}

    nonisolated func closeSocket(_ socket: Int32) {
        lock.lock()
        defer { lock.unlock() }
        closedSocketDescriptors.append(socket)
    }

    nonisolated func makeSession(abstract: UnsafeMutableRawPointer?) -> OpaquePointer? {
        lock.lock()
        sessionAbstractPointer = abstract
        lock.unlock()
        return sessionInitResult
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
        lock.lock()
        var abstract = sessionAbstractPointer
        lock.unlock()

        var responses = [LIBSSH2_USERAUTH_KBDINT_RESPONSE(text: nil, length: 0)]
        withUnsafeMutablePointer(to: &abstract) { abstractPointer in
            responses.withUnsafeMutableBufferPointer { responseBuffer in
                callback(
                    nil,
                    0,
                    nil,
                    0,
                    1,
                    nil,
                    responseBuffer.baseAddress,
                    abstractPointer
                )
            }
        }

        if let responseText = responses[0].text {
            let response = String(cString: responseText)
            let reportedLength = responses[0].length
            let terminator = responseText.advanced(by: Int(reportedLength)).pointee
            lock.lock()
            keyboardInteractiveResponseLog.append(response)
            keyboardInteractiveResponseBufferLog.append(
                KeyboardInteractiveResponseBuffer(
                    text: response,
                    reportedLength: reportedLength,
                    terminator: terminator
                )
            )
            lock.unlock()
            Darwin.free(responseText)
        }

        return responses[0].length > 0 ? 0 : LIBSSH2_ERROR_AUTHENTICATION_FAILED
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
        channelSendEOFResult
    }

    nonisolated func waitChannelEOF(_ channel: OpaquePointer) -> Int32 {
        channelWaitEOFResult
    }

    nonisolated func waitChannelClosed(_ channel: OpaquePointer) -> Int32 {
        channelWaitClosedResult
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
        lock.lock()
        disconnectInvocationCount += 1
        lock.unlock()
        if shouldBlockDisconnect {
            _ = disconnectReleaseSemaphore.wait(timeout: .now() + 5)
        }
        return 0
    }

    nonisolated func free(session: OpaquePointer) -> Int32 {
        0
    }
}
