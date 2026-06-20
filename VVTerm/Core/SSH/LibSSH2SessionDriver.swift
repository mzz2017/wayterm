import Foundation

// MARK: - libssh2 Runtime

/// libssh2 has process-global lifecycle (`libssh2_init`/`libssh2_exit`).
/// Initialize once and keep alive for the app lifetime to avoid tearing down
/// the library while other SSH sessions are still active.
private enum LibSSH2Runtime {
    private static let lock = NSLock()
    private static var initialized = false

    nonisolated static func ensureInitialized() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !initialized else { return }
        let rc = libssh2_init(0)
        guard rc == 0 else {
            throw SSHError.unknown("libssh2_init failed: \(rc)")
        }
        initialized = true
    }
}

struct LibSSH2ConnectedSocket: Sendable, Equatable {
    let descriptor: Int32
    let peerAddress: String?
}

struct LibSSH2RawError: Error, Sendable, Equatable {
    enum Operation: String, Sendable {
        case handshake
        case sessionDisconnect
        case sessionFree
    }

    let operation: Operation
    let code: Int32
    let message: String?
}

protocol LibSSH2SessionDriving: Sendable {
    nonisolated func ensureRuntimeInitialized() throws
    nonisolated func connectSocket(host: String, port: Int) throws -> LibSSH2ConnectedSocket
    nonisolated func configureInteractiveSocket(_ socket: Int32)
    nonisolated func closeSocket(_ socket: Int32)
    nonisolated func makeSession(abstract: UnsafeMutableRawPointer?) -> OpaquePointer?
    nonisolated func setMethodPreference(session: OpaquePointer, method: Int32, preferences: String)
    nonisolated func setBlocking(session: OpaquePointer, isBlocking: Bool)
    nonisolated func handshake(session: OpaquePointer, socket: Int32) -> Int32
    nonisolated func lastError(
        session: OpaquePointer,
        operation: LibSSH2RawError.Operation,
        fallbackCode: Int32
    ) -> LibSSH2RawError
    nonisolated func disconnect(session: OpaquePointer, reasonCode: Int32, description: String, language: String) -> Int32
    nonisolated func free(session: OpaquePointer) -> Int32
}

struct LibSSH2SessionDriver: LibSSH2SessionDriving {
    nonisolated func ensureRuntimeInitialized() throws {
        try LibSSH2Runtime.ensureInitialized()
    }

    nonisolated func connectSocket(host: String, port: Int) throws -> LibSSH2ConnectedSocket {
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

            let connectResult = Darwin.connect(candidateSocket, current.pointee.ai_addr, current.pointee.ai_addrlen)
            if connectResult == 0 {
                return LibSSH2ConnectedSocket(
                    descriptor: candidateSocket,
                    peerAddress: resolveNumericPeerAddress(for: candidateSocket)
                )
            }

            lastConnectError = errno
            Darwin.close(candidateSocket)
            candidate = current.pointee.ai_next
        }

        let message = lastConnectError == 0 ? "Unknown connect failure" : String(cString: strerror(lastConnectError))
        throw SSHError.connectionFailed("Failed to connect: \(message)")
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
