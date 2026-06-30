//
//  SSHSession.swift
//  VVTerm
//
//  libssh2 session lifecycle owner.
//

import Foundation
import os.log

// MARK: - SSH Session using libssh2

actor SSHSession {
    let config: SSHSessionConfig
    let driver: any LibSSH2SessionDriving
    var libssh2Session: OpaquePointer?
    var sftpSession: OpaquePointer?
    var shellChannels: [UUID: SSHSessionShellChannelState] = [:]
    var socket: Int32 = -1
    private var isActive = false
    var ioTask: Task<Void, Never>?
    nonisolated let channelCleanupTasks = SSHChannelCleanupTaskRegistry()
    var execRequests: [UUID: SSHSessionExecRequest] = [:]
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

        let connectedSocket = try driver.connectSocket(
            host: config.dialHost,
            port: config.dialPort,
            timeout: config.connectionTimeout
        )
        socket = connectedSocket.descriptor
        connectedPeerAddress = connectedSocket.peerAddress
        driver.configureInteractiveSocket(socket)

        do {
            try Task.checkCancellation()
        } catch {
            driver.closeSocket(socket)
            socket = -1
            connectedPeerAddress = nil
            throw error
        }

        // Create libssh2 session (use _ex variant since macros not available in Swift)
        // libssh2 stores this abstract pointer on the session and passes it back
        // synchronously during keyboard-interactive auth. SSHSession owns the
        // context for the whole libssh2 session lifetime, then clears the
        // password before connect() can return.
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
                        callback: keyboardInteractiveCallback
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
            let authLease = try await SSHAuthenticationGate.shared.acquireLease(for: authGateKey)
            logger.info("Acquired publickey auth slot [serverId: \(serverIdString, privacy: .public), user: \(username, privacy: .public)]")
            authResult = driver.authenticateWithPublicKey(
                session: session,
                username: username,
                keyData: keyData,
                publicKeyData: publicKeyData,
                passphrase: passphrase
            )
            await authLease.release()
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

    // MARK: - Keep Alive

    func sendKeepAlive() {
        guard let session = libssh2Session else { return }
        _ = driver.sendKeepAlive(session: session)
    }


}
