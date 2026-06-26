//
//  SSHSession.swift
//  VVTerm
//
//  libssh2 session lifecycle owner.
//

import Foundation
import os.log

// MARK: - SSH Session using libssh2

nonisolated actor SSHSession {
    nonisolated deinit {}

    private final class ExecRequest {
        let id: UUID
        let command: String
        let continuation: CheckedContinuation<String, Error>
        var channel: OpaquePointer?
        var output = Data()
        var stderr = Data()
        var isStarted = false

        init(id: UUID, command: String, continuation: CheckedContinuation<String, Error>) {
            self.id = id
            self.command = command
            self.continuation = continuation
        }
    }

    private final class ShellChannelState {
        let id: UUID
        var channel: OpaquePointer
        let continuation: AsyncStream<Data>.Continuation
        var batchBuffer = Data()
        var lastYieldTime: UInt64 = DispatchTime.now().uptimeNanoseconds
        var recentBytesPerRead: Int = 0

        init(id: UUID, channel: OpaquePointer, continuation: AsyncStream<Data>.Continuation) {
            self.id = id
            self.channel = channel
            self.continuation = continuation
        }
    }

    let config: SSHSessionConfig
    let driver: any LibSSH2SessionDriving
    var libssh2Session: OpaquePointer?
    var sftpSession: OpaquePointer?
    private var shellChannels: [UUID: ShellChannelState] = [:]
    private var socket: Int32 = -1
    private var isActive = false
    private var ioTask: Task<Void, Never>?
    nonisolated private let channelCleanupTasks = SSHChannelCleanupTaskRegistry()
    private var execRequests: [UUID: ExecRequest] = [:]
    private var connectedPeerAddress: String?
    let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VVTerm", category: "SSHSession")

    /// Atomic socket storage for emergency abort from any thread
    private let atomicSocket = AtomicSocket()

    /// Session-specific auth callback context passed to libssh2 session abstract pointer.
    private let keyboardInteractiveContext = KeyboardInteractiveContext()

    /// Track if cleanup has been performed
    private var hasBeenCleaned = false

    init(config: SSHSessionConfig, driver: any LibSSH2SessionDriving = LibSSH2SessionDriver()) {
        self.config = config
        self.driver = driver
    }

    var isConnected: Bool {
        isActive && libssh2Session != nil
    }

    /// Immediately abort the connection by closing the socket (can be called from any thread)
    nonisolated func abort() {
        atomicSocket.closeImmediately()
    }

    // MARK: - Connection

    func connect() async throws {
        try Task.checkCancellation()
        try driver.ensureRuntimeInitialized()
        socket = -1
        connectedPeerAddress = nil

        let connectedSocket = try driver.connectSocket(host: config.dialHost, port: config.dialPort)
        socket = connectedSocket.descriptor
        connectedPeerAddress = connectedSocket.peerAddress
        driver.configureInteractiveSocket(socket)

        // Create libssh2 session (use _ex variant since macros not available in Swift)
        let sessionAbstract = Unmanaged.passUnretained(keyboardInteractiveContext).toOpaque()
        libssh2Session = driver.makeSession(abstract: sessionAbstract)
        guard let session = libssh2Session else {
            driver.closeSocket(socket)
            socket = -1
            connectedPeerAddress = nil
            throw SSHError.unknown("Failed to create libssh2 session")
        }

        // Store in atomic storage only after libssh2 has a session owner.
        atomicSocket.socket = socket

        // Prefer fast ciphers - AES-GCM and ChaCha20 are hardware-accelerated on Apple Silicon
        // This reduces CPU overhead for encryption/decryption
        let fastCiphers = "aes128-gcm@openssh.com,aes256-gcm@openssh.com,chacha20-poly1305@openssh.com,aes128-ctr,aes256-ctr"
        driver.setMethodPreference(session: session, method: LIBSSH2_METHOD_CRYPT_CS, preferences: fastCiphers)
        driver.setMethodPreference(session: session, method: LIBSSH2_METHOD_CRYPT_SC, preferences: fastCiphers)

        // Prefer fast MACs (message authentication codes)
        let fastMACs = "hmac-sha2-256-etm@openssh.com,hmac-sha2-512-etm@openssh.com,hmac-sha2-256,hmac-sha2-512"
        driver.setMethodPreference(session: session, method: LIBSSH2_METHOD_MAC_CS, preferences: fastMACs)
        driver.setMethodPreference(session: session, method: LIBSSH2_METHOD_MAC_SC, preferences: fastMACs)

        // Set blocking mode for handshake
        driver.setBlocking(session: session, isBlocking: true)

        // Perform SSH handshake
        try Task.checkCancellation()
        let handshakeResult = driver.handshake(session: session, socket: socket)
        guard handshakeResult == 0 else {
            let rawError = driver.lastError(session: session, operation: .handshake, fallbackCode: handshakeResult)
            cleanup()
            throw SSHError.libssh2(rawError)
        }

        do {
            try await verifyHostKey()
        } catch {
            cleanup()
            throw error
        }

        // Authenticate
        try Task.checkCancellation()
        try await authenticate()

        // Set non-blocking for I/O
        driver.setBlocking(session: session, isBlocking: false)

        isActive = true
        logger.info("SSH session established")
    }

    private func authenticate() async throws {
        guard let session = libssh2Session else {
            throw SSHError.notConnected
        }

        let username = config.username
        var authResult: Int32 = -1

        // Query supported auth methods.
        let authDiscoveryResult = driver.supportedAuthenticationMethods(session: session, username: username)
        let authMethods: String?
        switch authDiscoveryResult {
        case .methods(let methods):
            authMethods = methods
            logger.info("Server auth methods [mode: \(self.config.connectionMode.rawValue)]: \(methods)")
        case .unavailable:
            authMethods = nil
            logger.warning("Could not get auth methods list")
        case .failure(let rawError):
            let errorMsg = rawError.message ?? "Unknown error"
            logger.error("Auth method discovery failed (\(rawError.code)): \(errorMsg)")
            throw SSHError.libssh2(rawError)
        }

        if config.connectionMode == .tailscale {
            if driver.isAuthenticated(session: session) {
                logger.info("Tailscale SSH authentication accepted by server policy")
                return
            }
            logger.error("Tailscale SSH auth not accepted by server")
            throw SSHError.tailscaleAuthenticationNotAccepted
        }

        // If authList is nil, check if already authenticated
        if authMethods == nil, driver.isAuthenticated(session: session) {
            logger.info("Already authenticated")
            return
        }

        switch config.authMethod {
        case .password:
            guard let password = config.credentials.password else {
                logger.error("No password provided")
                throw SSHError.authenticationFailed
            }
            logger.info("Attempting password auth for user: \(username)")

            authResult = driver.authenticateWithPassword(session: session, username: username, password: password)

            // If password auth fails, try keyboard-interactive ONLY if the server lists it.
            // When the method list is unavailable (nil), do not attempt it — guessing only
            // adds another failed-auth event toward sshd's penalty threshold.
            if authResult != 0 {
                let advertisesKbdInteractive = authMethods?.contains("keyboard-interactive") ?? false
                if advertisesKbdInteractive {
                    logger.info("Password auth failed, trying keyboard-interactive...")

                    keyboardInteractiveContext.setPassword(password)
                    defer { keyboardInteractiveContext.setPassword(nil) }

                    authResult = driver.authenticateWithKeyboardInteractive(
                        session: session,
                        username: username,
                        callback: kbdintCallback
                    )
                }
            }

        case .sshKey, .sshKeyWithPassphrase:
            guard let keyData = config.credentials.privateKey else {
                logger.error("No private key provided")
                throw SSHError.authenticationFailed
            }
            let passphrase = config.credentials.passphrase
            let publicKeyData = config.credentials.publicKey
            logger.info("Attempting publickey auth for user: \(username)")

            let serverIdString = config.credentials.serverId.uuidString
            let authGateKey = "\(serverIdString):\(username)"
            logger.info("Waiting for publickey auth slot [serverId: \(serverIdString, privacy: .public), user: \(username, privacy: .public)]")
            authResult = try await SSHAuthenticationGate.shared.withExclusiveAccess(for: authGateKey) {
                logger.info("Acquired publickey auth slot [serverId: \(serverIdString, privacy: .public), user: \(username, privacy: .public)]")
                return driver.authenticateWithPublicKey(
                    session: session,
                    username: username,
                    keyData: keyData,
                    publicKeyData: publicKeyData,
                    passphrase: passphrase
                )
            }
        }

        if authResult != 0 {
            let rawError = driver.lastError(session: session, operation: .authentication, fallbackCode: authResult)
            let errorMsg = rawError.message ?? "Unknown error"
            logger.error("Auth failed (\(rawError.code)): \(errorMsg)")
            if rawError.code != LIBSSH2_ERROR_AUTHENTICATION_FAILED {
                throw SSHError.libssh2(rawError)
            }
            throw SSHError.authenticationFailed
        }

        logger.info("Authentication successful")
    }

    private func verifyHostKey() async throws {
        guard let session = libssh2Session else {
            throw SSHError.notConnected
        }

        let (fingerprint, keyType) = try driver.hostKeyFingerprint(session: session)
        let host = config.hostKeyHost
        let port = config.hostKeyPort
        let verifier = KnownHostVerificationService()

        let result = try await verifier.verify(
            host: host,
            port: port,
            fingerprint: fingerprint,
            keyType: keyType
        )

        switch result {
        case .trusted:
            logger.info("Host key verified for \(host):\(port)")
        case .newHost:
            await verifier.trust(
                host: host,
                port: port,
                fingerprint: fingerprint,
                keyType: keyType
            )
            logger.info("Trusted new host key for \(host):\(port) (\(fingerprint))")
        case .changed(let knownFingerprint, let presentedFingerprint):
            logger.error("Host key mismatch for \(host):\(port). Known: \(knownFingerprint), Presented: \(presentedFingerprint)")
            throw SSHError.hostKeyVerificationFailed
        }
    }

    func disconnect() async {
        // Mark as inactive first to stop any pending operations
        isActive = false
        connectedPeerAddress = nil

        // Finish shell streams first to unblock any waiting consumers
        closeAllShellChannels()

        // Cancel IO task
        ioTask?.cancel()
        ioTask = nil

        // Fail any pending exec requests
        failAllExecRequests(error: SSHError.notConnected)
        await waitForChannelCleanupTasks()

        // Close socket first to abort any blocking I/O in libssh2
        atomicSocket.closeImmediately()
        socket = -1

        // Now cleanup libssh2 resources (won't block since socket is closed)
        cleanupLibssh2()

        logger.info("Disconnected")
    }

    private func cleanupLibssh2() {
        // Prevent double cleanup
        guard !hasBeenCleaned else { return }
        hasBeenCleaned = true

        closeSFTPSession()
        closeAllShellChannels()
        closeAllExecChannels()

        if let session = libssh2Session {
            let disconnectResult = driver.disconnect(
                session: session,
                reasonCode: 11,
                description: "Normal shutdown",
                language: ""
            )
            if disconnectResult != 0 {
                let rawError = driver.lastError(
                    session: session,
                    operation: .sessionDisconnect,
                    fallbackCode: disconnectResult
                )
                logger.debug(
                    "libssh2 disconnect returned \(rawError.code) [message: \(rawError.message ?? "none", privacy: .public)]"
                )
            }
            let freeResult = driver.free(session: session)
            if freeResult != 0, freeResult != LIBSSH2_ERROR_EAGAIN {
                let rawError = driver.lastError(
                    session: session,
                    operation: .sessionFree,
                    fallbackCode: freeResult
                )
                logger.debug(
                    "libssh2 session free returned \(rawError.code) [message: \(rawError.message ?? "none", privacy: .public)]"
                )
            }
            libssh2Session = nil
        }
    }

    private func cleanup() {
        // Close socket first to abort any blocking I/O
        atomicSocket.closeImmediately()
        socket = -1
        connectedPeerAddress = nil
        cleanupLibssh2()
    }

    func remoteEndpointHost() -> String? {
        connectedPeerAddress
    }

    // MARK: - Shell

    func logChannelFailure(
        session: OpaquePointer,
        operation: LibSSH2RawError.Operation,
        fallbackCode: Int32
    ) {
        let rawError = driver.lastError(session: session, operation: operation, fallbackCode: fallbackCode)
        logger.debug(
            "libssh2 \(operation.rawValue) returned \(rawError.code) [message: \(rawError.message ?? "none", privacy: .public)]"
        )
    }

    func libSSH2Error(
        session: OpaquePointer,
        operation: LibSSH2RawError.Operation,
        fallbackCode: Int32
    ) -> SSHError {
        let rawError = driver.lastError(
            session: session,
            operation: operation,
            fallbackCode: fallbackCode
        )
        logger.debug(
            "libssh2 \(operation.rawValue) returned \(rawError.code) [message: \(rawError.message ?? "none", privacy: .public)]"
        )
        return SSHError.libssh2(rawError)
    }

    func closeAndFreeChannel(_ channel: OpaquePointer) {
        let closeResult = driver.closeChannel(channel)
        if closeResult != 0, closeResult != LIBSSH2_ERROR_EAGAIN {
            if let session = libssh2Session {
                logChannelFailure(session: session, operation: .channelClose, fallbackCode: closeResult)
            } else {
                logger.debug("libssh2 channel close returned \(closeResult) [message: no active session]")
            }
        }

        let freeResult = driver.freeChannel(channel)
        if freeResult != 0, freeResult != LIBSSH2_ERROR_EAGAIN {
            if let session = libssh2Session {
                logChannelFailure(session: session, operation: .channelFree, fallbackCode: freeResult)
            } else {
                logger.debug("libssh2 channel free returned \(freeResult) [message: no active session]")
            }
        }
    }

    func startShell(
        cols: Int,
        rows: Int,
        startupCommand: String? = nil,
        environment: RemoteEnvironment = .fallbackPOSIX,
        terminalType: RemoteTerminalType = RemoteTerminalBootstrap.defaultTerminalType
    ) async throws -> ShellHandle {
        guard let session = libssh2Session else {
            throw SSHError.notConnected
        }

        // Set blocking for channel setup
        driver.setBlocking(session: session, isBlocking: true)
        defer { driver.setBlocking(session: session, isBlocking: false) }

        guard let channel = driver.openSessionChannel(session: session) else {
            logChannelFailure(session: session, operation: .channelOpen, fallbackCode: 0)
            throw SSHError.channelOpenFailed
        }

        // Mirror Ghostty's SSH behavior so remote prompts/themes can detect
        // 24-bit color support without changing TERM compatibility.
        for variable in RemoteTerminalBootstrap.terminalEnvironment() {
            let result = driver.setChannelEnvironment(
                channel: channel,
                name: variable.name,
                value: variable.value
            )

            // Many SSH servers gate env forwarding via AcceptEnv; continue when
            // a variable is rejected so interactive sessions still start.
            if result != 0 {
                logger.debug("Remote SSH server rejected env \(variable.name, privacy: .public): \(result)")
            }
        }

        // Request PTY
        let ptyResult = driver.requestPty(
            channel: channel,
            terminalType: terminalType,
            cols: cols,
            rows: rows
        )
        guard ptyResult == 0 else {
            logChannelFailure(session: session, operation: .channelRequestPty, fallbackCode: ptyResult)
            closeAndFreeChannel(channel)
            throw SSHError.shellRequestFailed
        }

        // Route shell startup through a single bootstrap helper so SSH, tmux,
        // and mosh share the same environment and quoting behavior.
        switch RemoteTerminalBootstrap.launchPlan(startupCommand: startupCommand, environment: environment) {
        case .shell:
            let shellResult = driver.startShell(channel: channel)
            guard shellResult == 0 else {
                logChannelFailure(session: session, operation: .channelProcessStartup, fallbackCode: shellResult)
                closeAndFreeChannel(channel)
                throw SSHError.shellRequestFailed
            }
        case .exec(let command):
            let execResult = driver.startExec(channel: channel, command: command)
            guard execResult == 0 else {
                logChannelFailure(session: session, operation: .channelProcessStartup, fallbackCode: execResult)
                closeAndFreeChannel(channel)
                throw SSHError.shellRequestFailed
            }
        }

        logger.info("Shell started (\(cols)x\(rows))")

        let shellId = UUID()
        let stream = AsyncStream<Data> { continuation in
            let state = ShellChannelState(id: shellId, channel: channel, continuation: continuation)
            self.shellChannels[shellId] = state

            continuation.onTermination = { [weak self] _ in
                self?.trackChannelCleanupTask { [weak self] in
                    await self?.closeShell(shellId)
                }
            }
        }

        // Start IO loop
        startIOLoop()

        return ShellHandle(id: shellId, stream: stream)
    }
    private func startIOLoop() {
        guard ioTask == nil else { return }
        ioTask = Task { [weak self] in
            await self?.ioLoop()
        }
    }

    private func stopIOLoop() {
        ioTask?.cancel()
        ioTask = nil
    }

    private func ioLoop() async {
        var buffer = [CChar](repeating: 0, count: 32768)
        let batchThreshold = 65536  // 64KB batch threshold

        // Adaptive batch delay: track data rate to switch between interactive and bulk modes
        // Interactive mode (keystrokes): 1ms delay for minimum latency
        // Bulk mode (command output): 5ms delay for better throughput
        let interactiveDelay: UInt64 = 1_000_000   // 1ms
        let bulkDelay: UInt64 = 5_000_000          // 5ms
        let interactiveThreshold = 100             // bytes - below this is interactive
        let bulkThreshold = 1000                   // bytes - above this is bulk

        while !Task.isCancelled, libssh2Session != nil {
            var didWork = false

            if !shellChannels.isEmpty {
                let states = Array(shellChannels.values)
                for state in states {
                    let bytesRead = driver.readChannel(state.channel, stream: 0, into: &buffer)

                    if bytesRead > 0 {
                        let readCount = Int(bytesRead)
                        state.batchBuffer.append(Data(bytes: buffer, count: readCount))
                        didWork = true

                        // Update exponential moving average (alpha = 0.3 for quick adaptation)
                        state.recentBytesPerRead = (state.recentBytesPerRead * 7 + readCount * 3) / 10

                        // Adaptive delay based on data rate
                        let maxBatchDelay: UInt64
                        if state.recentBytesPerRead < interactiveThreshold {
                            maxBatchDelay = interactiveDelay  // Fast for keystrokes
                        } else if state.recentBytesPerRead > bulkThreshold {
                            maxBatchDelay = bulkDelay         // Slower for bulk data
                        } else {
                            // Linear interpolation between modes
                            let ratio = UInt64(state.recentBytesPerRead - interactiveThreshold) * 100 / UInt64(bulkThreshold - interactiveThreshold)
                            maxBatchDelay = interactiveDelay + (bulkDelay - interactiveDelay) * ratio / 100
                        }

                        // Yield batch when threshold reached or enough time passed
                        let now = DispatchTime.now().uptimeNanoseconds
                        let timeSinceYield = now - state.lastYieldTime

                        if state.batchBuffer.count >= batchThreshold || timeSinceYield >= maxBatchDelay {
                            state.continuation.yield(state.batchBuffer)
                            state.batchBuffer = Data()
                            state.lastYieldTime = now
                        }
                    } else if bytesRead == Int(LIBSSH2_ERROR_EAGAIN) {
                        // Flush any pending data before waiting
                        if !state.batchBuffer.isEmpty {
                            state.continuation.yield(state.batchBuffer)
                            state.batchBuffer = Data()
                            state.lastYieldTime = DispatchTime.now().uptimeNanoseconds
                        }
                        // Reset to interactive mode when idle (waiting for input)
                        state.recentBytesPerRead = 0
                    } else if bytesRead < 0 {
                        // Error - flush remaining data first
                        if !state.batchBuffer.isEmpty {
                            state.continuation.yield(state.batchBuffer)
                        }
                        logger.error("Read error: \(bytesRead)")
                        closeShellInternal(state.id)
                        continue
                    }

                    // Check for EOF
                    if driver.isChannelEOF(state.channel) {
                        if !state.batchBuffer.isEmpty {
                            state.continuation.yield(state.batchBuffer)
                        }
                        logger.info("Channel EOF")
                        closeShellInternal(state.id)
                        didWork = true
                    }
                }
            }

            if !execRequests.isEmpty {
                let requestIds = Array(execRequests.keys)
                for requestId in requestIds {
                    guard let request = execRequests[requestId] else { continue }
                    guard ensureExecChannelReady(request) else { continue }

                    guard let execChannel = request.channel else { continue }

                    let bytesRead = driver.readChannel(execChannel, stream: 0, into: &buffer)
                    if bytesRead > 0 {
                        request.output.append(Data(bytes: buffer, count: Int(bytesRead)))
                        didWork = true
                    } else if bytesRead == Int(LIBSSH2_ERROR_EAGAIN) {
                        // No data yet
                    } else if bytesRead < 0 {
                        finishExecRequest(requestId, error: SSHError.socketError("Exec read failed: \(bytesRead)"))
                        continue
                    }

                    let stderrRead = driver.readChannel(execChannel, stream: 1, into: &buffer)
                    if stderrRead > 0 {
                        request.stderr.append(Data(bytes: buffer, count: Int(stderrRead)))
                        didWork = true
                    } else if stderrRead == Int(LIBSSH2_ERROR_EAGAIN) {
                        // No stderr data yet
                    } else if stderrRead < 0 {
                        finishExecRequest(requestId, error: SSHError.socketError("Exec stderr read failed: \(stderrRead)"))
                        continue
                    }

                    if let currentChannel = request.channel, driver.isChannelEOF(currentChannel) {
                        finishExecRequest(requestId, error: nil)
                        didWork = true
                    }
                }
            }

            if shellChannels.isEmpty, execRequests.isEmpty {
                break
            }

            if !didWork {
                await waitForSocket()
            }

            // Always yield to prevent starving other tasks (especially important during rapid typing)
            // This ensures write operations and UI updates get CPU time
            await Task.yield()
        }

        closeAllShellChannels()
        stopIOLoop()
    }

    func closeShell(_ shellId: UUID) async {
        closeShellInternal(shellId)
    }

    nonisolated private func trackChannelCleanupTask(_ operation: @escaping @Sendable () async -> Void) {
        channelCleanupTasks.track(operation)
    }

    private func waitForChannelCleanupTasks() async {
        while true {
            let tasks = channelCleanupTasks.tasks()
            guard !tasks.isEmpty else { return }
            for task in tasks {
                await task.value
            }
        }
    }

    private func closeShellInternal(_ shellId: UUID) {
        guard let state = shellChannels.removeValue(forKey: shellId) else { return }
        if !state.batchBuffer.isEmpty {
            state.continuation.yield(state.batchBuffer)
        }
        closeAndFreeChannel(state.channel)
        state.continuation.onTermination = nil
        state.continuation.finish()
    }

    private func closeAllShellChannels() {
        let states = shellChannels
        shellChannels.removeAll()
        for state in states.values {
            if !state.batchBuffer.isEmpty {
                state.continuation.yield(state.batchBuffer)
            }
            closeAndFreeChannel(state.channel)
            state.continuation.onTermination = nil
            state.continuation.finish()
        }
    }

    private func closeAllExecChannels() {
        for request in execRequests.values {
            if let channel = request.channel {
                closeAndFreeChannel(channel)
                request.channel = nil
            }
        }
        execRequests.removeAll()
    }

    private func failAllExecRequests(error: Error) {
        let requests = execRequests
        execRequests.removeAll()
        for request in requests.values {
            if let channel = request.channel {
                closeAndFreeChannel(channel)
                request.channel = nil
            }
            request.continuation.resume(throwing: error)
        }
    }

    private func ensureExecChannelReady(_ request: ExecRequest) -> Bool {
        guard let session = libssh2Session else {
            finishExecRequest(request.id, error: SSHError.notConnected)
            return false
        }

        if request.channel == nil {
            let newChannel = driver.openSessionChannel(session: session)
            if let newChannel = newChannel {
                request.channel = newChannel
            } else {
                let rawError = driver.lastError(session: session, operation: .channelOpen, fallbackCode: 0)
                if rawError.code == LIBSSH2_ERROR_EAGAIN {
                    return false
                }
                finishExecRequest(request.id, error: SSHError.libssh2(rawError))
                return false
            }
        }

        if !request.isStarted, let execChannel = request.channel {
            let execResult = driver.startExec(channel: execChannel, command: request.command)
            if execResult == Int32(LIBSSH2_ERROR_EAGAIN) {
                return false
            }
            if execResult != 0 {
                let error = libSSH2Error(
                    session: session,
                    operation: .channelProcessStartup,
                    fallbackCode: execResult
                )
                finishExecRequest(request.id, error: error)
                return false
            }
            request.isStarted = true
        }

        return true
    }

    private func cancelExecRequest(_ requestId: UUID, error: Error) {
        guard execRequests[requestId] != nil else { return }
        finishExecRequest(requestId, error: error)
    }

    private func finishExecRequest(_ requestId: UUID, error: Error?) {
        guard let request = execRequests.removeValue(forKey: requestId) else { return }

        if let channel = request.channel {
            closeAndFreeChannel(channel)
            request.channel = nil
        }

        if let error = error {
            request.continuation.resume(throwing: error)
        } else {
            if !request.stderr.isEmpty,
               let stderr = String(data: request.stderr, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !stderr.isEmpty {
                logger.debug("Exec command stderr: \(stderr, privacy: .public)")
            }
            let output = String(data: request.output, encoding: .utf8) ?? ""
            request.continuation.resume(returning: output)
        }
    }

    func waitForSocket() async {
        guard let session = libssh2Session, socket >= 0 else { return }

        let direction = driver.sessionBlockDirections(session: session)
        guard direction != 0 else { return }

        // Use poll() for reliable, low-overhead socket waiting
        // This is simpler and more reliable than DispatchSource for this use case
        var pfd = pollfd()
        pfd.fd = socket
        pfd.events = 0

        if direction & LIBSSH2_SESSION_BLOCK_INBOUND != 0 {
            pfd.events |= Int16(POLLIN)
        }
        if direction & LIBSSH2_SESSION_BLOCK_OUTBOUND != 0 {
            pfd.events |= Int16(POLLOUT)
        }

        // Poll with 5ms timeout - short enough for responsiveness, long enough to avoid busy spinning
        _ = poll(&pfd, 1, 5)
    }

    // MARK: - Write

    func write(_ data: Data, to shellId: UUID) async throws {
        guard let state = shellChannels[shellId] else {
            throw SSHError.notConnected
        }

        let bytes = [UInt8](data)
        var remaining = bytes.count
        var offset = 0

        while remaining > 0 {
            try Task.checkCancellation()
            let written = driver.writeChannel(
                state.channel,
                stream: 0,
                bytes: bytes,
                offset: offset,
                remaining: remaining
            )

            if written > 0 {
                offset += written
                remaining -= written
            } else if written == Int(LIBSSH2_ERROR_EAGAIN) {
                // Would block - actually wait for socket to be ready
                await waitForSocket()
                try Task.checkCancellation()
            } else {
                throw SSHError.socketError("Write failed: \(written)")
            }
        }
    }

    // MARK: - Resize

    func resize(cols: Int, rows: Int, for shellId: UUID) async throws {
        guard let state = shellChannels[shellId] else {
            throw SSHError.notConnected
        }

        let result = driver.requestPtySize(channel: state.channel, cols: cols, rows: rows)
        if result != 0 && result != Int32(LIBSSH2_ERROR_EAGAIN) {
            logger.warning("PTY resize failed: \(result)")
        }
    }

    // MARK: - Execute Command

    func execute(_ command: String) async throws -> String {
        guard libssh2Session != nil else {
            throw SSHError.notConnected
        }

        let requestId = UUID()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                let request = ExecRequest(id: requestId, command: command, continuation: continuation)
                execRequests[request.id] = request
                startIOLoop()
            }
        }, onCancel: { [weak self] in
            self?.trackChannelCleanupTask { [weak self] in
                await self?.cancelExecRequest(requestId, error: CancellationError())
            }
        })
    }

    // MARK: - Keep Alive

    func sendKeepAlive() {
        guard let session = libssh2Session else { return }
        _ = driver.sendKeepAlive(session: session)
    }


}

// MARK: - fd_set helpers for select()

private func fdZero(_ set: inout fd_set) {
    set.fds_bits = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}

private func fdSet(_ fd: Int32, _ set: inout fd_set) {
    guard fd >= 0, fd < FD_SETSIZE else { return }
    let intOffset = Int(fd) / 32
    let bitOffset = Int(fd) % 32
    withUnsafeMutableBytes(of: &set.fds_bits) { buf in
        guard let baseAddress = buf.baseAddress,
              intOffset * MemoryLayout<Int32>.size < buf.count else { return }
        let ptr = baseAddress.assumingMemoryBound(to: Int32.self)
        ptr[intOffset] |= Int32(1 << bitOffset)
    }
}
