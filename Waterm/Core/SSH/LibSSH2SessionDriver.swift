import Foundation

// MARK: - libssh2 Runtime

/// libssh2 has process-global lifecycle (`libssh2_init`/`libssh2_exit`).
/// Initialize once and keep alive for the app lifetime to avoid tearing down
/// the library while other SSH sessions are still active.
nonisolated private enum LibSSH2Runtime {
    private static let initializationState = LibSSH2RuntimeInitializationState()

    nonisolated static func ensureInitialized() throws {
        try initializationState.ensureInitialized {
            let rc = libssh2_init(0)
            guard rc == 0 else {
                throw SSHError.unknown("libssh2_init failed: \(rc)")
            }
        }
    }
}

nonisolated final class LibSSH2RuntimeInitializationState: @unchecked Sendable {
    private let lock = NSLock()
    private var initialized = false

    func ensureInitialized(_ initialize: () throws -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !initialized else { return }
        try initialize()
        initialized = true
    }
}

struct LibSSH2ConnectedSocket: Sendable, Equatable {
    let descriptor: Int32
    let peerAddress: String?
}

struct LibSSH2RawError: Error, Sendable, Equatable {
    enum Operation: String, Sendable {
        case authentication
        case channelClose
        case channelEOF
        case channelFree
        case channelOpen
        case channelProcessStartup
        case channelRead
        case channelRequestPty
        case channelRequestPtySize
        case channelSetEnvironment
        case channelWaitClosed
        case channelWaitEOF
        case channelWrite
        case handshake
        case scpChannelOpen
        case sessionDisconnect
        case sessionBlockDirections
        case sessionFree
        case sftpCloseHandle
        case sftpInit
        case sftpLastError
        case sftpMakeDirectory
        case sftpOpen
        case sftpRead
        case sftpReadDirectory
        case sftpRename
        case sftpRemoveDirectory
        case sftpSeek
        case sftpSetStat
        case sftpShutdown
        case sftpStat
        case sftpStatVFS
        case sftpSymlink
        case sftpUnlink
        case sftpWrite
    }

    let operation: Operation
    let code: Int32
    let message: String?
}

enum LibSSH2AuthenticationMethodDiscoveryResult: Sendable, Equatable {
    case methods(String)
    case unavailable
    case failure(LibSSH2RawError)
}

typealias LibSSH2KeyboardInteractiveCallback = @convention(c) (
    UnsafePointer<CChar>?,
    Int32,
    UnsafePointer<CChar>?,
    Int32,
    Int32,
    UnsafePointer<LIBSSH2_USERAUTH_KBDINT_PROMPT>?,
    UnsafeMutablePointer<LIBSSH2_USERAUTH_KBDINT_RESPONSE>?,
    UnsafeMutablePointer<UnsafeMutableRawPointer?>?
) -> Void

protocol LibSSH2SessionDriving: Sendable {
    nonisolated func ensureRuntimeInitialized() throws
    nonisolated func connectSocket(host: String, port: Int, timeout: TimeInterval) throws -> LibSSH2ConnectedSocket
    nonisolated func configureInteractiveSocket(_ socket: Int32)
    nonisolated func closeSocket(_ socket: Int32)
    nonisolated func makeSession(abstract: UnsafeMutableRawPointer?) -> OpaquePointer?
    nonisolated func setMethodPreference(session: OpaquePointer, method: Int32, preferences: String)
    nonisolated func setBlocking(session: OpaquePointer, isBlocking: Bool)
    nonisolated func handshake(session: OpaquePointer, socket: Int32) -> Int32
    nonisolated func hostKeyFingerprint(session: OpaquePointer) throws -> (fingerprint: String, keyType: Int)
    nonisolated func supportedAuthenticationMethods(
        session: OpaquePointer,
        username: String
    ) -> LibSSH2AuthenticationMethodDiscoveryResult
    nonisolated func isAuthenticated(session: OpaquePointer) -> Bool
    nonisolated func authenticateWithPassword(session: OpaquePointer, username: String, password: String) -> Int32
    nonisolated func authenticateWithKeyboardInteractive(
        session: OpaquePointer,
        username: String,
        callback: LibSSH2KeyboardInteractiveCallback
    ) -> Int32
    nonisolated func authenticateWithPublicKey(
        session: OpaquePointer,
        username: String,
        keyData: Data,
        publicKeyData: Data?,
        passphrase: String?
    ) -> Int32
    nonisolated func openSessionChannel(session: OpaquePointer) -> OpaquePointer?
    nonisolated func setChannelEnvironment(channel: OpaquePointer, name: String, value: String) -> Int32
    nonisolated func requestPty(
        channel: OpaquePointer,
        terminalType: RemoteTerminalType,
        cols: Int,
        rows: Int
    ) -> Int32
    nonisolated func startShell(channel: OpaquePointer) -> Int32
    nonisolated func startExec(channel: OpaquePointer, command: String) -> Int32
    nonisolated func closeChannel(_ channel: OpaquePointer) -> Int32
    nonisolated func freeChannel(_ channel: OpaquePointer) -> Int32
    nonisolated func readChannel(_ channel: OpaquePointer, stream: Int32, into buffer: inout [CChar]) -> Int
    nonisolated func writeChannel(
        _ channel: OpaquePointer,
        stream: Int32,
        bytes: [UInt8],
        offset: Int,
        remaining: Int
    ) -> Int
    nonisolated func isChannelEOF(_ channel: OpaquePointer) -> Bool
    nonisolated func sendChannelEOF(_ channel: OpaquePointer) -> Int32
    nonisolated func waitChannelEOF(_ channel: OpaquePointer) -> Int32
    nonisolated func waitChannelClosed(_ channel: OpaquePointer) -> Int32
    nonisolated func channelExitStatus(_ channel: OpaquePointer) -> Int32
    nonisolated func requestPtySize(channel: OpaquePointer, cols: Int, rows: Int) -> Int32
    nonisolated func handleExtendedData(channel: OpaquePointer, mode: Int32) -> Int32
    nonisolated func openSCPChannel(
        session: OpaquePointer,
        path: String,
        permissions: Int32,
        size: Int64
    ) -> OpaquePointer?
    nonisolated func sessionBlockDirections(session: OpaquePointer) -> Int32
    nonisolated func initSFTPSession(session: OpaquePointer) -> OpaquePointer?
    nonisolated func shutdownSFTPSession(_ sftp: OpaquePointer) -> Int32
    nonisolated func openSFTPHandle(
        sftp: OpaquePointer,
        path: String,
        flags: UInt32,
        mode: Int32,
        openType: Int32
    ) -> OpaquePointer?
    nonisolated func closeSFTPHandle(_ handle: OpaquePointer) -> Int32
    nonisolated func readSFTPDirectory(
        handle: OpaquePointer,
        into nameBuffer: inout [CChar],
        attributes: inout LIBSSH2_SFTP_ATTRIBUTES
    ) -> Int
    nonisolated func seekSFTPFile(handle: OpaquePointer, offset: UInt64)
    nonisolated func readSFTPFile(handle: OpaquePointer, into buffer: inout [CChar]) -> Int
    nonisolated func writeSFTPFile(handle: OpaquePointer, data: Data, offset: Int, maxLength: Int) -> Int
    nonisolated func statSFTPPath(
        sftp: OpaquePointer,
        path: String,
        statType: Int32,
        attributes: inout LIBSSH2_SFTP_ATTRIBUTES
    ) -> Int32
    nonisolated func readSFTPSymlink(
        sftp: OpaquePointer,
        path: String,
        targetBuffer: inout [CChar],
        linkType: Int32
    ) -> Int
    nonisolated func statSFTPFileSystem(
        sftp: OpaquePointer,
        path: String,
        status: inout LIBSSH2_SFTP_STATVFS
    ) -> Int32
    nonisolated func makeSFTPDirectory(sftp: OpaquePointer, path: String, permissions: Int32) -> Int
    nonisolated func renameSFTPPath(
        sftp: OpaquePointer,
        sourcePath: String,
        destinationPath: String,
        flags: Int
    ) -> Int
    nonisolated func unlinkSFTPFile(sftp: OpaquePointer, path: String) -> Int
    nonisolated func removeSFTPDirectory(sftp: OpaquePointer, path: String) -> Int
    nonisolated func lastSFTPError(_ sftp: OpaquePointer) -> UInt
    nonisolated func sendKeepAlive(session: OpaquePointer) -> Int32
    nonisolated func lastError(
        session: OpaquePointer,
        operation: LibSSH2RawError.Operation,
        fallbackCode: Int32
    ) -> LibSSH2RawError
    nonisolated func disconnect(session: OpaquePointer, reasonCode: Int32, description: String, language: String) -> Int32
    nonisolated func free(session: OpaquePointer) -> Int32
}

nonisolated struct LibSSH2SessionDriver: LibSSH2SessionDriving {
    nonisolated func ensureRuntimeInitialized() throws {
        try LibSSH2Runtime.ensureInitialized()
    }

    nonisolated func connectSocket(host: String, port: Int, timeout: TimeInterval) throws -> LibSSH2ConnectedSocket {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP
        var result: UnsafeMutablePointer<addrinfo>?

        let portString = String(port)
        let resolveResult = getaddrinfo(host, portString, &hints, &result)
        guard resolveResult == 0, let addrInfo = result else {
            throw SSHError.connectionFailed("Failed to resolve host: \(host)")
        }
        defer { freeaddrinfo(result) }

        var lastConnectError: Int32 = 0
        var candidate: UnsafeMutablePointer<addrinfo>? = addrInfo

        while let current = candidate {
            let family = current.pointee.ai_family
            let sockType = current.pointee.ai_socktype == 0 ? SOCK_STREAM : current.pointee.ai_socktype
            let protocolNumber = current.pointee.ai_protocol

            let candidateSocket = Darwin.socket(family, sockType, protocolNumber)
            if candidateSocket < 0 {
                lastConnectError = errno
                candidate = current.pointee.ai_next
                continue
            }

            let connectError = connectNonBlocking(
                socket: candidateSocket,
                address: current.pointee.ai_addr,
                addressLength: current.pointee.ai_addrlen,
                timeout: timeout
            )
            if connectError == 0 {
                return LibSSH2ConnectedSocket(
                    descriptor: candidateSocket,
                    peerAddress: resolveNumericPeerAddress(for: candidateSocket)
                )
            }

            lastConnectError = connectError
            Darwin.close(candidateSocket)
            candidate = current.pointee.ai_next
        }

        if lastConnectError == ETIMEDOUT {
            throw SSHError.timeout
        }
        let message = lastConnectError == 0 ? "Unknown connect failure" : String(cString: strerror(lastConnectError))
        throw SSHError.connectionFailed("Failed to connect: \(message)")
    }

    private nonisolated func connectNonBlocking(
        socket: Int32,
        address: UnsafePointer<sockaddr>,
        addressLength: socklen_t,
        timeout: TimeInterval
    ) -> Int32 {
        let originalFlags = fcntl(socket, F_GETFL, 0)
        if originalFlags >= 0 {
            _ = fcntl(socket, F_SETFL, originalFlags | O_NONBLOCK)
        }

        let connectResult = Darwin.connect(socket, address, addressLength)
        if connectResult == 0 {
            if originalFlags >= 0 {
                _ = fcntl(socket, F_SETFL, originalFlags)
            }
            return 0
        }

        guard errno == EINPROGRESS else {
            return errno
        }

        var pollDescriptor = pollfd(fd: socket, events: Int16(POLLOUT), revents: 0)
        let timeoutMilliseconds = max(1, min(Int(timeout * 1000), Int(Int32.max)))
        while true {
            let pollResult = poll(&pollDescriptor, 1, Int32(timeoutMilliseconds))
            if pollResult == 0 {
                return ETIMEDOUT
            }
            if pollResult < 0 {
                if errno == EINTR {
                    continue
                }
                return errno
            }

            var socketError: Int32 = 0
            var socketErrorLength = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(socket, SOL_SOCKET, SO_ERROR, &socketError, &socketErrorLength) == 0 else {
                return errno
            }
            if socketError == 0 {
                if originalFlags >= 0 {
                    _ = fcntl(socket, F_SETFL, originalFlags)
                }
                return 0
            }
            return socketError
        }
    }

    nonisolated func configureInteractiveSocket(_ socket: Int32) {
        // Disable Nagle's algorithm for low-latency interactive typing.
        var noDelay: Int32 = 1
        setsockopt(socket, IPPROTO_TCP, TCP_NODELAY, &noDelay, socklen_t(MemoryLayout<Int32>.size))

        // Keep buffers tuned for interactive SSH: small sends, larger receives.
        var sendBufSize: Int32 = 8192
        var recvBufSize: Int32 = 65536
        setsockopt(socket, SOL_SOCKET, SO_SNDBUF, &sendBufSize, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(socket, SOL_SOCKET, SO_RCVBUF, &recvBufSize, socklen_t(MemoryLayout<Int32>.size))

        var noSigPipe: Int32 = 1
        setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
    }

    nonisolated func closeSocket(_ socket: Int32) {
        Darwin.close(socket)
    }

    nonisolated func makeSession(abstract: UnsafeMutableRawPointer?) -> OpaquePointer? {
        libssh2_session_init_ex(nil, nil, nil, abstract)
    }

    nonisolated func setMethodPreference(session: OpaquePointer, method: Int32, preferences: String) {
        libssh2_session_method_pref(session, method, preferences)
    }

    nonisolated func setBlocking(session: OpaquePointer, isBlocking: Bool) {
        libssh2_session_set_blocking(session, isBlocking ? 1 : 0)
    }

    nonisolated func handshake(session: OpaquePointer, socket: Int32) -> Int32 {
        libssh2_session_handshake(session, socket)
    }

    nonisolated func hostKeyFingerprint(session: OpaquePointer) throws -> (fingerprint: String, keyType: Int) {
        guard let hashPtr = libssh2_hostkey_hash(session, Int32(LIBSSH2_HOSTKEY_HASH_SHA256)) else {
            throw SSHError.hostKeyVerificationFailed
        }

        let hash = Data(bytes: hashPtr, count: 32)
        let base64 = hash.base64EncodedString().trimmingCharacters(in: CharacterSet(charactersIn: "="))
        let fingerprint = "SHA256:\(base64)"

        var keyLen: size_t = 0
        var keyType: Int32 = 0
        _ = libssh2_session_hostkey(session, &keyLen, &keyType)

        return (fingerprint, Int(keyType))
    }

    nonisolated func supportedAuthenticationMethods(
        session: OpaquePointer,
        username: String
    ) -> LibSSH2AuthenticationMethodDiscoveryResult {
        guard let authList = libssh2_userauth_list(session, username, UInt32(username.utf8.count)) else {
            let rawError = lastError(session: session, operation: .authentication, fallbackCode: 0)
            if rawError.code != 0, rawError.code != LIBSSH2_ERROR_AUTHENTICATION_FAILED {
                return .failure(rawError)
            }
            return .unavailable
        }
        return .methods(String(cString: authList))
    }

    nonisolated func isAuthenticated(session: OpaquePointer) -> Bool {
        libssh2_userauth_authenticated(session) != 0
    }

    nonisolated func authenticateWithPassword(session: OpaquePointer, username: String, password: String) -> Int32 {
        libssh2_userauth_password_ex(
            session,
            username,
            UInt32(username.utf8.count),
            password,
            UInt32(password.utf8.count),
            nil
        )
    }

    nonisolated func authenticateWithKeyboardInteractive(
        session: OpaquePointer,
        username: String,
        callback: LibSSH2KeyboardInteractiveCallback
    ) -> Int32 {
        libssh2_userauth_keyboard_interactive_ex(
            session,
            username,
            UInt32(username.utf8.count),
            callback
        )
    }

    nonisolated func authenticateWithPublicKey(
        session: OpaquePointer,
        username: String,
        keyData: Data,
        publicKeyData: Data?,
        passphrase: String?
    ) -> Int32 {
        keyData.withUnsafeBytes { rawBuffer -> Int32 in
            guard let baseAddress = rawBuffer.bindMemory(to: CChar.self).baseAddress else {
                return LIBSSH2_ERROR_ALLOC
            }

            if let publicKeyData, !publicKeyData.isEmpty {
                return publicKeyData.withUnsafeBytes { publicBuffer -> Int32 in
                    guard let publicBase = publicBuffer.bindMemory(to: CChar.self).baseAddress else {
                        return LIBSSH2_ERROR_ALLOC
                    }
                    return libssh2_userauth_publickey_frommemory(
                        session,
                        username,
                        Int(username.utf8.count),
                        publicBase,
                        Int(publicKeyData.count),
                        baseAddress,
                        Int(keyData.count),
                        passphrase
                    )
                }
            }

            return libssh2_userauth_publickey_frommemory(
                session,
                username,
                Int(username.utf8.count),
                nil,
                0,
                baseAddress,
                Int(keyData.count),
                passphrase
            )
        }
    }

    nonisolated func openSessionChannel(session: OpaquePointer) -> OpaquePointer? {
        libssh2_channel_open_ex(
            session,
            "session",
            UInt32("session".utf8.count),
            2 * 1024 * 1024,
            32768,
            nil,
            0
        )
    }

    nonisolated func setChannelEnvironment(channel: OpaquePointer, name: String, value: String) -> Int32 {
        libssh2_channel_setenv_ex(
            channel,
            name,
            UInt32(name.utf8.count),
            value,
            UInt32(value.utf8.count)
        )
    }

    nonisolated func requestPty(
        channel: OpaquePointer,
        terminalType: RemoteTerminalType,
        cols: Int,
        rows: Int
    ) -> Int32 {
        libssh2_channel_request_pty_ex(
            channel,
            terminalType.rawValue,
            UInt32(terminalType.rawValue.utf8.count),
            nil,
            0,
            Int32(cols),
            Int32(rows),
            0,
            0
        )
    }

    nonisolated func startShell(channel: OpaquePointer) -> Int32 {
        libssh2_channel_process_startup(channel, "shell", 5, nil, 0)
    }

    nonisolated func startExec(channel: OpaquePointer, command: String) -> Int32 {
        command.withCString { commandPointer in
            libssh2_channel_process_startup(
                channel,
                "exec",
                4,
                commandPointer,
                UInt32(command.utf8.count)
            )
        }
    }

    nonisolated func closeChannel(_ channel: OpaquePointer) -> Int32 {
        libssh2_channel_close(channel)
    }

    nonisolated func freeChannel(_ channel: OpaquePointer) -> Int32 {
        libssh2_channel_free(channel)
    }

    nonisolated func readChannel(_ channel: OpaquePointer, stream: Int32, into buffer: inout [CChar]) -> Int {
        buffer.withUnsafeMutableBufferPointer { mutableBuffer in
            guard let baseAddress = mutableBuffer.baseAddress else { return -1 }
            return Int(libssh2_channel_read_ex(channel, stream, baseAddress, mutableBuffer.count))
        }
    }

    nonisolated func writeChannel(
        _ channel: OpaquePointer,
        stream: Int32,
        bytes: [UInt8],
        offset: Int,
        remaining: Int
    ) -> Int {
        bytes.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return -1 }
            let pointer = UnsafeRawPointer(baseAddress.advanced(by: offset)).assumingMemoryBound(to: CChar.self)
            return Int(libssh2_channel_write_ex(channel, stream, pointer, remaining))
        }
    }

    nonisolated func isChannelEOF(_ channel: OpaquePointer) -> Bool {
        libssh2_channel_eof(channel) != 0
    }

    nonisolated func sendChannelEOF(_ channel: OpaquePointer) -> Int32 {
        libssh2_channel_send_eof(channel)
    }

    nonisolated func waitChannelEOF(_ channel: OpaquePointer) -> Int32 {
        libssh2_channel_wait_eof(channel)
    }

    nonisolated func waitChannelClosed(_ channel: OpaquePointer) -> Int32 {
        libssh2_channel_wait_closed(channel)
    }

    nonisolated func channelExitStatus(_ channel: OpaquePointer) -> Int32 {
        libssh2_channel_get_exit_status(channel)
    }

    nonisolated func requestPtySize(channel: OpaquePointer, cols: Int, rows: Int) -> Int32 {
        libssh2_channel_request_pty_size_ex(channel, Int32(cols), Int32(rows), 0, 0)
    }

    nonisolated func handleExtendedData(channel: OpaquePointer, mode: Int32) -> Int32 {
        libssh2_channel_handle_extended_data2(channel, mode)
    }

    nonisolated func openSCPChannel(
        session: OpaquePointer,
        path: String,
        permissions: Int32,
        size: Int64
    ) -> OpaquePointer? {
        path.withCString { pathPointer in
            libssh2_scp_send64(
                session,
                pathPointer,
                permissions,
                size,
                0,
                0
            )
        }
    }

    nonisolated func sessionBlockDirections(session: OpaquePointer) -> Int32 {
        libssh2_session_block_directions(session)
    }

    nonisolated func initSFTPSession(session: OpaquePointer) -> OpaquePointer? {
        libssh2_sftp_init(session)
    }

    nonisolated func shutdownSFTPSession(_ sftp: OpaquePointer) -> Int32 {
        libssh2_sftp_shutdown(sftp)
    }

    nonisolated func openSFTPHandle(
        sftp: OpaquePointer,
        path: String,
        flags: UInt32,
        mode: Int32,
        openType: Int32
    ) -> OpaquePointer? {
        path.withCString { pathPointer in
            libssh2_sftp_open_ex(
                sftp,
                pathPointer,
                UInt32(path.utf8.count),
                UInt(flags),
                Int(mode),
                openType
            )
        }
    }

    nonisolated func closeSFTPHandle(_ handle: OpaquePointer) -> Int32 {
        libssh2_sftp_close_handle(handle)
    }

    nonisolated func readSFTPDirectory(
        handle: OpaquePointer,
        into nameBuffer: inout [CChar],
        attributes: inout LIBSSH2_SFTP_ATTRIBUTES
    ) -> Int {
        nameBuffer.withUnsafeMutableBufferPointer { buffer -> Int in
            guard let baseAddress = buffer.baseAddress else {
                return Int(LIBSSH2_ERROR_EAGAIN)
            }
            return Int(
                libssh2_sftp_readdir_ex(
                    handle,
                    baseAddress,
                    buffer.count,
                    nil,
                    0,
                    &attributes
                )
            )
        }
    }

    nonisolated func seekSFTPFile(handle: OpaquePointer, offset: UInt64) {
        libssh2_sftp_seek64(handle, offset)
    }

    nonisolated func readSFTPFile(handle: OpaquePointer, into buffer: inout [CChar]) -> Int {
        buffer.withUnsafeMutableBufferPointer { bufferPointer -> Int in
            guard let baseAddress = bufferPointer.baseAddress else {
                return Int(LIBSSH2_ERROR_EAGAIN)
            }
            return Int(libssh2_sftp_read(handle, baseAddress, bufferPointer.count))
        }
    }

    nonisolated func writeSFTPFile(handle: OpaquePointer, data: Data, offset: Int, maxLength: Int) -> Int {
        data.withUnsafeBytes { rawBuffer -> Int in
            guard let baseAddress = rawBuffer.baseAddress else { return 0 }
            let writeBaseAddress = baseAddress
                .advanced(by: offset)
                .assumingMemoryBound(to: CChar.self)
            return Int(libssh2_sftp_write(handle, writeBaseAddress, maxLength))
        }
    }

    nonisolated func statSFTPPath(
        sftp: OpaquePointer,
        path: String,
        statType: Int32,
        attributes: inout LIBSSH2_SFTP_ATTRIBUTES
    ) -> Int32 {
        path.withCString { pathPointer in
            libssh2_sftp_stat_ex(
                sftp,
                pathPointer,
                UInt32(path.utf8.count),
                statType,
                &attributes
            )
        }
    }

    nonisolated func readSFTPSymlink(
        sftp: OpaquePointer,
        path: String,
        targetBuffer: inout [CChar],
        linkType: Int32
    ) -> Int {
        targetBuffer.withUnsafeMutableBufferPointer { bufferPointer -> Int in
            guard let baseAddress = bufferPointer.baseAddress else {
                return Int(LIBSSH2_ERROR_EAGAIN)
            }
            return path.withCString { pathPointer in
                Int(
                    libssh2_sftp_symlink_ex(
                        sftp,
                        pathPointer,
                        UInt32(path.utf8.count),
                        baseAddress,
                        UInt32(bufferPointer.count),
                        linkType
                    )
                )
            }
        }
    }

    nonisolated func statSFTPFileSystem(
        sftp: OpaquePointer,
        path: String,
        status: inout LIBSSH2_SFTP_STATVFS
    ) -> Int32 {
        path.withCString { pathPointer in
            libssh2_sftp_statvfs(
                sftp,
                pathPointer,
                path.utf8.count,
                &status
            )
        }
    }

    nonisolated func makeSFTPDirectory(sftp: OpaquePointer, path: String, permissions: Int32) -> Int {
        path.withCString { pathPointer in
            Int(
                libssh2_sftp_mkdir_ex(
                    sftp,
                    pathPointer,
                    UInt32(path.utf8.count),
                    Int(permissions)
                )
            )
        }
    }

    nonisolated func renameSFTPPath(
        sftp: OpaquePointer,
        sourcePath: String,
        destinationPath: String,
        flags: Int
    ) -> Int {
        sourcePath.withCString { sourcePointer in
            destinationPath.withCString { destinationPointer in
                Int(
                    libssh2_sftp_rename_ex(
                        sftp,
                        sourcePointer,
                        UInt32(sourcePath.utf8.count),
                        destinationPointer,
                        UInt32(destinationPath.utf8.count),
                        flags
                    )
                )
            }
        }
    }

    nonisolated func unlinkSFTPFile(sftp: OpaquePointer, path: String) -> Int {
        path.withCString { pathPointer in
            Int(libssh2_sftp_unlink_ex(sftp, pathPointer, UInt32(path.utf8.count)))
        }
    }

    nonisolated func removeSFTPDirectory(sftp: OpaquePointer, path: String) -> Int {
        path.withCString { pathPointer in
            Int(libssh2_sftp_rmdir_ex(sftp, pathPointer, UInt32(path.utf8.count)))
        }
    }

    nonisolated func lastSFTPError(_ sftp: OpaquePointer) -> UInt {
        UInt(libssh2_sftp_last_error(sftp))
    }

    nonisolated func sendKeepAlive(session: OpaquePointer) -> Int32 {
        var secondsToNext: Int32 = 0
        return libssh2_keepalive_send(session, &secondsToNext)
    }

    nonisolated func lastError(
        session: OpaquePointer,
        operation: LibSSH2RawError.Operation,
        fallbackCode: Int32
    ) -> LibSSH2RawError {
        var errmsg: UnsafeMutablePointer<CChar>?
        var errmsgLength: Int32 = 0
        let code = libssh2_session_last_error(session, &errmsg, &errmsgLength, 0)
        let message = errmsg.map { String(cString: $0) }
        return LibSSH2RawError(
            operation: operation,
            code: code == 0 ? fallbackCode : code,
            message: message
        )
    }

    nonisolated func disconnect(session: OpaquePointer, reasonCode: Int32, description: String, language: String) -> Int32 {
        libssh2_session_disconnect_ex(session, reasonCode, description, language)
    }

    nonisolated func free(session: OpaquePointer) -> Int32 {
        libssh2_session_free(session)
    }

    private nonisolated func resolveNumericPeerAddress(for socket: Int32) -> String? {
        var storage = sockaddr_storage()
        var storageLen = socklen_t(MemoryLayout<sockaddr_storage>.size)

        let peerResult = withUnsafeMutablePointer(to: &storage) { storagePtr in
            storagePtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                getpeername(socket, sockaddrPtr, &storageLen)
            }
        }
        guard peerResult == 0 else { return nil }

        var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let nameResult = withUnsafePointer(to: &storage) { storagePtr in
            storagePtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                getnameinfo(
                    sockaddrPtr,
                    storageLen,
                    &hostBuffer,
                    socklen_t(hostBuffer.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                )
            }
        }
        guard nameResult == 0 else { return nil }
        return String(cString: hostBuffer)
    }
}
