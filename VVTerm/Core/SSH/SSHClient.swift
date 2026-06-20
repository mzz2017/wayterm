import Foundation
import os.log
import MoshCore
import MoshBootstrap

// MARK: - SSH Client using libssh2

struct ShellHandle {
    let id: UUID
    let stream: AsyncStream<Data>
    let transport: ShellTransport
    let fallbackReason: MoshFallbackReason?

    init(
        id: UUID,
        stream: AsyncStream<Data>,
        transport: ShellTransport = .ssh,
        fallbackReason: MoshFallbackReason? = nil
    ) {
        self.id = id
        self.stream = stream
        self.transport = transport
        self.fallbackReason = fallbackReason
    }
}

enum SSHUploadStrategy: Sendable {
    case automatic
    case execPreferred
}

private final class SSHClientAbortState: @unchecked Sendable {
    private let lock = NSLock()
    private var aborted = false
    private var sessionForAbort: SSHSession?

    var isAborted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return aborted
    }

    func reset() {
        lock.lock()
        aborted = false
        lock.unlock()
    }

    func setSessionForAbort(_ session: SSHSession?) {
        lock.lock()
        sessionForAbort = session
        lock.unlock()
    }

    func abort() {
        lock.lock()
        aborted = true
        let session = sessionForAbort
        lock.unlock()
        session?.abort()
    }
}

actor SSHClient {
    private struct MoshShellRuntime {
        let session: MoshClientSession
    }

    private var session: SSHSession?
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VVTerm", category: "SSH")
    private var keepAliveTask: Task<Void, Never>?
    private var connectTask: Task<SSHSession, Error>?
    private var pendingConnectSession: SSHSession?
    private var connectionKey: String?
    private var connectedServer: Server?
    private var resolvedRemoteEnvironment: RemoteEnvironment?
    private var resolvedRemoteTerminalType: RemoteTerminalType?
    private var moshShells: [UUID: MoshShellRuntime] = [:]
    private let cloudflareTransportManager = CloudflareTransportManager()
    private let moshStartupTimeout: Duration = .seconds(8)
    private let connectTimeout: Duration = .seconds(30)
    private let disconnectTimeout: Duration = .seconds(4)
    private let shellStartTimeout: Duration = .seconds(20)
    private let execTimeout: Duration = .seconds(20)
    private let downloadTimeout: Duration = .seconds(120)
    private let uploadTimeout: Duration = .seconds(60)
    private let abortState = SSHClientAbortState()

    /// Immediately abort the connection by closing the socket (non-blocking, can be called from any thread)
    nonisolated func abort() {
        abortState.abort()
    }

    /// Check if the client has been aborted
    var isAborted: Bool {
        abortState.isAborted
    }

    // MARK: - Connection

    func connect(to server: Server, credentials: ServerCredentials) async throws -> SSHSession {
        abortState.reset()
        try Task.checkCancellation()

        let key = "\(server.host):\(server.port):\(server.username):\(server.connectionMode):\(server.authMethod):\(server.cloudflareAccessMode?.rawValue ?? "none"):\(server.cloudflareTeamDomainOverride ?? "")"

        if let session = session, await session.isConnected, connectionKey == key {
            connectedServer = server
            return session
        }

        if let task = connectTask, connectionKey == key {
            let connected = try await task.value
            connectedServer = server
            return connected
        }

        if let session = session, await session.isConnected, connectionKey != key {
            throw SSHError.connectionFailed("SSH client already connected")
        }

        logger.info("Connecting to \(server.host):\(server.port) [mode: \(server.connectionMode.rawValue)]")
        logger.info("Auth method: \(String(describing: server.authMethod)), password present: \(credentials.password != nil)")

        var dialHost = server.host
        var dialPort = server.port

        if server.connectionMode == .cloudflare {
            let localPort = try await cloudflareTransportManager.connect(server: server, credentials: credentials)
            dialHost = "127.0.0.1"
            dialPort = Int(localPort)
            logger.info("Using Cloudflare local tunnel endpoint \(dialHost):\(dialPort)")
        } else {
            await disconnectCloudflareTransport(reason: "pre-connect cleanup")
        }

        let config = SSHSessionConfig(
            host: server.host,
            port: server.port,
            dialHost: dialHost,
            dialPort: dialPort,
            hostKeyHost: server.host,
            hostKeyPort: server.port,
            username: server.username,
            connectionMode: server.connectionMode,
            authMethod: server.authMethod,
            credentials: credentials
        )

        let pendingSession = SSHSession(config: config)
        pendingConnectSession = pendingSession
        abortState.setSessionForAbort(pendingSession)

        let task = Task { [connectTimeout] () -> SSHSession in
            try Task.checkCancellation()
            do {
                try await SSHClient.runWithTimeout(
                    connectTimeout,
                    operation: {
                        try await pendingSession.connect()
                    },
                    onTimeout: {
                        pendingSession.abort()
                    }
                )
                try Task.checkCancellation()
                return pendingSession
            } catch {
                pendingSession.abort()
                await pendingSession.disconnect()
                throw error
            }
        }

        connectTask = task
        connectionKey = key

        do {
            let session = try await task.value
            pendingConnectSession = nil
            if abortState.isAborted || Task.isCancelled || task.isCancelled {
                session.abort()
                await session.disconnect()
                connectTask = nil
                connectionKey = nil
                self.session = nil
                abortState.setSessionForAbort(nil)
                self.connectedServer = nil
                await disconnectCloudflareTransport(reason: "connect cancellation")
                throw CancellationError()
            }
            self.session = session
            abortState.setSessionForAbort(session)
            self.connectedServer = server
            self.resolvedRemoteEnvironment = nil
            self.resolvedRemoteTerminalType = nil
            startKeepAlive()
            connectTask = nil
            logger.info("Connected to \(server.host)")
            return session
        } catch {
            pendingConnectSession = nil
            connectTask = nil
            connectionKey = nil
            self.session = nil
            abortState.setSessionForAbort(nil)
            self.connectedServer = nil
            self.resolvedRemoteEnvironment = nil
            self.resolvedRemoteTerminalType = nil
            await disconnectCloudflareTransport(reason: "connect failure")
            if server.connectionMode == .cloudflare,
               case SSHError.libssh2(let rawError) = error,
               rawError.operation == .handshake,
               rawError.code == LIBSSH2_ERROR_SOCKET_RECV {
                throw SSHError.cloudflareTunnelFailed(
                    String(
                        localized: "Cloudflare tunnel connected, but SSH handshake was closed by the upstream target. Verify Access policy and service token scope."
                    )
                )
            }
            throw error
        }
    }

    func disconnect() async {
        abortState.abort()

        let activeMoshShells = Array(moshShells.values)
        moshShells.removeAll()
        for runtime in activeMoshShells {
            await runtime.session.stop()
        }

        keepAliveTask?.cancel()
        keepAliveTask = nil
        connectTask?.cancel()
        connectTask = nil
        pendingConnectSession?.abort()
        pendingConnectSession = nil
        connectionKey = nil

        let activeSession = session
        session = nil
        abortState.setSessionForAbort(nil)
        connectedServer = nil
        resolvedRemoteEnvironment = nil
        resolvedRemoteTerminalType = nil
        await disconnectSSHSession(activeSession)
        await disconnectCloudflareTransport(reason: "client disconnect")

        logger.info("Disconnected")
    }

    // MARK: - Command Execution

    func execute(_ command: String, timeout: Duration? = nil) async throws -> String {
        guard !abortState.isAborted else {
            throw SSHError.notConnected
        }
        guard let session = session else {
            throw SSHError.notConnected
        }
        let effectiveTimeout = timeout ?? execTimeout
        return try await SSHClient.runWithTimeout(effectiveTimeout) {
            try Task.checkCancellation()
            return try await session.execute(command)
        }
    }

    func upload(
        _ data: Data,
        to remotePath: String,
        permissions: Int32 = 0o600,
        strategy: SSHUploadStrategy = .automatic
    ) async throws {
        guard !abortState.isAborted else {
            throw SSHError.notConnected
        }
        guard let session = session else {
            throw SSHError.notConnected
        }

        logger.info(
            "Starting SSH upload [path: \(remotePath, privacy: .public)] [bytes: \(data.count)] [strategy: \(String(describing: strategy), privacy: .public)]"
        )
        try await SSHClient.runWithTimeout(uploadTimeout) {
            try Task.checkCancellation()
            try await session.upload(
                data,
                to: remotePath,
                permissions: permissions,
                strategy: strategy
            )
        }
    }

    func remoteEnvironment(forceRefresh: Bool = false) async -> RemoteEnvironment {
        if !forceRefresh, let resolvedRemoteEnvironment {
            return resolvedRemoteEnvironment
        }

        let environment = await RemoteEnvironmentResolver.resolve(using: self)
        resolvedRemoteEnvironment = environment
        logger.info(
            "Resolved remote environment [platform: \(environment.platform.rawValue, privacy: .public), shell: \(environment.shellProfile.family.rawValue, privacy: .public), active: \(environment.activeShellName ?? "unknown", privacy: .public)]"
        )
        return environment
    }

    func remoteTerminalType(forceRefresh: Bool = false) async -> RemoteTerminalType {
        if !forceRefresh, let resolvedRemoteTerminalType {
            return resolvedRemoteTerminalType
        }

        let environment = await remoteEnvironment(forceRefresh: forceRefresh)
        let terminalType = await RemoteTerminalTypeResolver.resolve(
            environment: environment,
            execute: { [weak self] command, timeout in
                guard let self else { throw SSHError.notConnected }
                return try await self.execute(command, timeout: timeout)
            }
        )
        resolvedRemoteTerminalType = terminalType
        logger.info("Resolved remote terminal type: \(terminalType.rawValue, privacy: .public)")
        return terminalType
    }

    func remotePlatform(forceRefresh: Bool = false) async -> RemotePlatform {
        await remoteEnvironment(forceRefresh: forceRefresh).platform
    }

    func supportsTmuxRuntime() async -> Bool {
        let environment = await remoteEnvironment()
        return environment.supportsTmuxRuntime
    }

    func supportsMoshRuntime() async -> Bool {
        let environment = await remoteEnvironment()
        return environment.supportsMoshRuntime
    }

    // MARK: - Remote Files

    func listDirectory(at path: String, maxEntries: Int? = nil) async throws -> [RemoteFileEntry] {
        guard !abortState.isAborted, let session = session else {
            throw RemoteFileBrowserError.disconnected
        }
        return try await session.listDirectory(at: path, maxEntries: maxEntries)
    }

    func stat(at path: String) async throws -> RemoteFileEntry {
        guard !abortState.isAborted, let session = session else {
            throw RemoteFileBrowserError.disconnected
        }
        return try await session.stat(at: path)
    }

    func lstat(at path: String) async throws -> RemoteFileEntry {
        guard !abortState.isAborted, let session = session else {
            throw RemoteFileBrowserError.disconnected
        }
        return try await session.lstat(at: path)
    }

    func readlink(at path: String) async throws -> String {
        guard !abortState.isAborted, let session = session else {
            throw RemoteFileBrowserError.disconnected
        }
        return try await session.readlink(at: path)
    }

    func readFile(at path: String, maxBytes: Int, offset: UInt64 = 0) async throws -> Data {
        guard !abortState.isAborted, let session = session else {
            throw RemoteFileBrowserError.disconnected
        }
        return try await session.readFile(at: path, maxBytes: maxBytes, offset: offset)
    }

    func fileSystemStatus(at path: String) async throws -> RemoteFileFilesystemStatus {
        guard !abortState.isAborted, let session = session else {
            throw RemoteFileBrowserError.disconnected
        }
        return try await session.fileSystemStatus(at: path)
    }

    func downloadFile(at path: String, to localURL: URL) async throws {
        guard !abortState.isAborted, let session = session else {
            throw RemoteFileBrowserError.disconnected
        }

        logger.info(
            "Starting SSH download [remote: \(path, privacy: .public)] [local: \(localURL.path, privacy: .private(mask: .hash))]"
        )
        try await SSHClient.runWithTimeout(downloadTimeout) {
            try Task.checkCancellation()
            try await session.downloadFile(at: path, to: localURL)
        }
    }

    func resolveHomeDirectory() async throws -> String {
        guard !abortState.isAborted, let session = session else {
            throw RemoteFileBrowserError.disconnected
        }
        return try await session.resolveHomeDirectory()
    }

    func createDirectory(at path: String, permissions: Int32 = 0o755) async throws {
        guard !abortState.isAborted, let session = session else {
            throw RemoteFileBrowserError.disconnected
        }
        try await session.createDirectory(at: path, permissions: permissions)
    }

    func setPermissions(at path: String, permissions: UInt32) async throws {
        guard !abortState.isAborted, let session = session else {
            throw RemoteFileBrowserError.disconnected
        }
        try await session.setPermissions(at: path, permissions: permissions)
    }

    func renameItem(at sourcePath: String, to destinationPath: String) async throws {
        guard !abortState.isAborted, let session = session else {
            throw RemoteFileBrowserError.disconnected
        }
        try await session.renameItem(at: sourcePath, to: destinationPath)
    }

    func deleteFile(at path: String) async throws {
        guard !abortState.isAborted, let session = session else {
            throw RemoteFileBrowserError.disconnected
        }
        try await session.deleteFile(at: path)
    }

    func deleteDirectory(at path: String) async throws {
        guard !abortState.isAborted, let session = session else {
            throw RemoteFileBrowserError.disconnected
        }
        try await session.deleteDirectory(at: path)
    }

    // MARK: - Shell

    func startShell(cols: Int = 80, rows: Int = 24, startupCommand: String? = nil) async throws -> ShellHandle {
        guard let session = session else {
            throw SSHError.notConnected
        }

        let connectionMode = connectedServer?.connectionMode ?? .standard
        let environment = await remoteEnvironment()
        let terminalType = await remoteTerminalType()
        if connectionMode != .mosh {
            let sshShell = try await startSSHShell(
                using: session,
                cols: cols,
                rows: rows,
                startupCommand: startupCommand,
                environment: environment,
                terminalType: terminalType
            )
            return ShellHandle(
                id: sshShell.id,
                stream: sshShell.stream,
                transport: .ssh
            )
        }

        guard environment.platform != .windows && environment.shellProfile.family == .posix else {
            logger.warning("Mosh requested, but remote environment does not support Mosh runtime. Falling back to SSH.")
            let fallbackShell = try await startSSHShell(
                using: session,
                cols: cols,
                rows: rows,
                startupCommand: startupCommand,
                environment: environment,
                terminalType: terminalType
            )
            return ShellHandle(
                id: fallbackShell.id,
                stream: fallbackShell.stream,
                transport: .sshFallback,
                fallbackReason: .unsupportedRemoteCapabilities
            )
        }

        do {
            return try await startMoshShell(cols: cols, rows: rows, startupCommand: startupCommand)
        } catch {
            if error is CancellationError || Task.isCancelled {
                throw CancellationError()
            }
            let moshError = error
            let fallbackReason = fallbackReason(for: moshError)
            logger.warning("Mosh startup failed, using SSH fallback: \(moshError.localizedDescription)")

            do {
                let fallbackShell = try await startSSHShell(
                    using: session,
                    cols: cols,
                    rows: rows,
                    startupCommand: startupCommand,
                    environment: environment,
                    terminalType: terminalType
                )
                return ShellHandle(
                    id: fallbackShell.id,
                    stream: fallbackShell.stream,
                    transport: .sshFallback,
                    fallbackReason: fallbackReason
                )
            } catch {
                throw SSHError.moshSessionFailed(
                    "Mosh startup failed (\(moshError.localizedDescription)); SSH fallback failed (\(error.localizedDescription))"
                )
            }
        }
    }

    private func startSSHShell(
        using session: SSHSession,
        cols: Int,
        rows: Int,
        startupCommand: String?,
        environment: RemoteEnvironment,
        terminalType: RemoteTerminalType
    ) async throws -> ShellHandle {
        try await SSHClient.runWithTimeout(
            shellStartTimeout,
            operation: {
                try await session.startShell(
                    cols: cols,
                    rows: rows,
                    startupCommand: startupCommand,
                    environment: environment,
                    terminalType: terminalType
                )
            },
            onTimeout: {
                session.abort()
            }
        )
    }

    func write(_ data: Data, to shellId: UUID) async throws {
        guard !abortState.isAborted else {
            throw SSHError.notConnected
        }

        if let runtime = moshShells[shellId] {
            do {
                try await runtime.session.enqueue(.keystrokes(data))
                return
            } catch {
                throw SSHError.moshSessionFailed(error.localizedDescription)
            }
        }

        guard let session = session else {
            throw SSHError.notConnected
        }
        try await session.write(data, to: shellId)
    }

    func resize(cols: Int, rows: Int, for shellId: UUID) async throws {
        if let runtime = moshShells[shellId] {
            do {
                try await runtime.session.enqueue(.resize(cols: Int32(cols), rows: Int32(rows)))
                return
            } catch {
                throw SSHError.moshSessionFailed(error.localizedDescription)
            }
        }

        guard let session = session else {
            throw SSHError.notConnected
        }
        try await session.resize(cols: cols, rows: rows, for: shellId)
    }

    func closeShell(_ shellId: UUID) async {
        if let runtime = moshShells.removeValue(forKey: shellId) {
            await runtime.session.stop()
            return
        }

        guard let session = session else { return }
        await session.closeShell(shellId)
    }

    // MARK: - Keep Alive

    private func startKeepAlive(interval: TimeInterval = 30) {
        keepAliveTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { break }
                await session?.sendKeepAlive()
            }
        }
    }

    private func disconnectSSHSession(_ activeSession: SSHSession?) async {
        guard let activeSession else { return }
        do {
            try await SSHClient.runWithTimeout(disconnectTimeout) {
                await activeSession.disconnect()
            }
        } catch {
            logger.warning("Timed out while disconnecting SSH session; aborting socket")
            activeSession.abort()
        }
    }

    private func disconnectCloudflareTransport(reason: String) async {
        do {
            try await SSHClient.runWithTimeout(disconnectTimeout) { [cloudflareTransportManager] in
                await cloudflareTransportManager.disconnect()
            }
        } catch {
            logger.warning("Timed out while disconnecting Cloudflare transport (\(reason, privacy: .public))")
        }
    }

    // MARK: - State

    var isConnected: Bool {
        get async {
            await session?.isConnected ?? false
        }
    }

    // MARK: - Mosh

    private func startMoshShell(
        cols: Int,
        rows: Int,
        startupCommand: String?
    ) async throws -> ShellHandle {
        let configuredHost = connectedServer?.host.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !configuredHost.isEmpty else {
            throw SSHError.moshBootstrapFailed("Missing server host for Mosh endpoint")
        }

        var candidateHosts: [String] = [configuredHost]
        if let sshSession = session,
           let peerHost = await sshSession.remoteEndpointHost() {
            let trimmedPeerHost = peerHost.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedPeerHost.isEmpty && trimmedPeerHost != configuredHost {
                candidateHosts.append(trimmedPeerHost)
            }
        }

        let connectInfo = try await RemoteMoshManager.shared.bootstrapConnectInfo(
            using: self,
            startCommand: startupCommand,
            portRange: 60001...61000
        )

        let startupTimeout = candidateHosts.count > 1 ? Duration.seconds(4) : moshStartupTimeout
        var lastStartupError: Error?
        var moshSession: MoshClientSession?

        for host in candidateHosts {
            let endpoint = MoshEndpoint(
                host: host,
                port: connectInfo.port,
                keyBase64_22: connectInfo.key
            )
            let candidateSession = MoshClientSession(endpoint: endpoint)

            do {
                try await SSHClient.runWithTimeout(startupTimeout) {
                    try await candidateSession.start()
                    try await candidateSession.enqueue(.resize(cols: Int32(cols), rows: Int32(rows)))
                }
                moshSession = candidateSession
                if host != configuredHost {
                    logger.info("Using SSH peer endpoint for Mosh: \(host, privacy: .public)")
                }
                break
            } catch {
                await candidateSession.stop()
                if error is CancellationError || Task.isCancelled {
                    throw CancellationError()
                }
                lastStartupError = error
                if host != candidateHosts.last {
                    logger.warning("Mosh startup failed for endpoint \(host, privacy: .public), trying next candidate")
                }
            }
        }

        guard let moshSession else {
            if let sshError = lastStartupError as? SSHError,
               case .timeout = sshError {
                throw SSHError.moshSessionFailed("Timed out waiting for Mosh UDP session startup")
            }
            if let lastStartupError {
                throw SSHError.moshSessionFailed(lastStartupError.localizedDescription)
            }
            throw SSHError.moshSessionFailed("Failed to start Mosh session")
        }

        let shellId = UUID()
        let pendingOps = await moshSession.drainHostOps()
        if !pendingOps.isEmpty {
            logger.info("Mosh: \(pendingOps.count) pending host ops before stream creation")
        }
        let hostOpStream = await moshSession.hostOpStream()
        let moshLogger = logger
        let stream = AsyncStream<Data> { continuation in
            // Replay any ops that arrived before the stream was created
            for op in pendingOps {
                if case .hostBytes(let bytes) = op {
                    continuation.yield(bytes)
                }
            }
            let streamTask = Task { [weak self] in
                var totalBytes = 0
                for await hostOp in hostOpStream {
                    guard !Task.isCancelled else { break }
                    switch hostOp {
                    case .hostBytes(let bytes):
                        totalBytes += bytes.count
                        if totalBytes <= 2000 {
                            let preview = String(data: bytes, encoding: .utf8)?
                                .replacingOccurrences(of: "\u{1b}", with: "\\e")
                                .replacingOccurrences(of: "\r", with: "\\r")
                                .replacingOccurrences(of: "\n", with: "\\n")
                                .prefix(300) ?? "<binary>"
                            moshLogger.info("Mosh hostBytes: \(bytes.count)B (total: \(totalBytes)) content: \(preview)")
                        }
                        continuation.yield(bytes)
                    case .echoAck, .resize:
                        break
                    }
                }
                moshLogger.info("Mosh stream ended, total bytes delivered: \(totalBytes)")
                continuation.finish()
                await self?.closeShell(shellId)
            }

            continuation.onTermination = { [weak self] _ in
                streamTask.cancel()
                Task { [weak self] in
                    await self?.closeShell(shellId)
                }
            }
        }

        moshShells[shellId] = MoshShellRuntime(session: moshSession)
        return ShellHandle(
            id: shellId,
            stream: stream,
            transport: .mosh
        )
    }

    nonisolated static func runWithTimeout<T: Sendable>(
        _ timeout: Duration,
        operation: @escaping @Sendable () async throws -> T,
        onTimeout: (@Sendable () async -> Void)? = nil
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                if let onTimeout {
                    await onTimeout()
                }
                throw SSHError.timeout
            }

            do {
                guard let result = try await group.next() else {
                    throw SSHError.timeout
                }
                group.cancelAll()
                return result
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }

    private func fallbackReason(for error: Error) -> MoshFallbackReason {
        guard let sshError = error as? SSHError else {
            return .sessionFailed
        }

        switch sshError {
        case .moshServerMissing:
            return .serverMissing
        case .moshBootstrapFailed:
            return .bootstrapFailed
        case .moshSessionFailed:
            return .sessionFailed
        default:
            return .sessionFailed
        }
    }
}

actor SSHConnectionOperationService {
    static let shared = SSHConnectionOperationService()

    private init() {}

    func runWithConnection<T>(
        using client: SSHClient,
        server: Server,
        credentials: ServerCredentials,
        disconnectWhenDone: Bool = false,
        operation: @escaping (SSHClient) async throws -> T
    ) async throws -> T {
        do {
            _ = try await client.connect(to: server, credentials: credentials)
            let result = try await operation(client)
            if disconnectWhenDone {
                await client.disconnect()
            }
            return result
        } catch {
            if disconnectWhenDone {
                await client.disconnect()
            }
            throw error
        }
    }

    func withTemporaryConnection<T>(
        server: Server,
        credentials: ServerCredentials,
        operation: @escaping (SSHClient) async throws -> T
    ) async throws -> T {
        let client = SSHClient()
        return try await runWithConnection(
            using: client,
            server: server,
            credentials: credentials,
            disconnectWhenDone: true,
            operation: operation
        )
    }
}

// MARK: - Keyboard Interactive Auth Helper

/// Per-session storage for keyboard-interactive password (used by C callback).
/// This avoids cross-session password races when multiple auth flows run concurrently.
private final class KeyboardInteractiveContext: @unchecked Sendable {
    private nonisolated(unsafe) var _password: String?
    private let lock = NSLock()

    nonisolated init() {}

    nonisolated func setPassword(_ password: String?) {
        lock.lock()
        defer { lock.unlock() }
        _password = password
    }

    nonisolated func password() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return _password
    }
}

private func keyboardInteractivePassword(
    from abstract: UnsafeMutablePointer<UnsafeMutableRawPointer?>?
) -> String? {
    guard let abstract, let contextPointer = abstract.pointee else { return nil }
    let context = Unmanaged<KeyboardInteractiveContext>.fromOpaque(contextPointer).takeUnretainedValue()
    return context.password()
}

// C callback for keyboard-interactive authentication
nonisolated(unsafe) private let kbdintCallback: @convention(c) (
    UnsafePointer<CChar>?,  // name
    Int32,                   // name_len
    UnsafePointer<CChar>?,  // instruction
    Int32,                   // instruction_len
    Int32,                   // num_prompts
    UnsafePointer<LIBSSH2_USERAUTH_KBDINT_PROMPT>?,  // prompts
    UnsafeMutablePointer<LIBSSH2_USERAUTH_KBDINT_RESPONSE>?,  // responses
    UnsafeMutablePointer<UnsafeMutableRawPointer?>?  // abstract
) -> Void = { name, nameLen, instruction, instructionLen, numPrompts, prompts, responses, abstract in
    guard numPrompts > 0, let responses = responses, let password = keyboardInteractivePassword(from: abstract) else {
        return
    }

    // For each prompt, provide the password
    for i in 0..<Int(numPrompts) {
        let passwordData = password.utf8CString
        let length = passwordData.count - 1  // exclude null terminator

        // Allocate memory for response (libssh2 will free it)
        let responseBuf = UnsafeMutablePointer<CChar>.allocate(capacity: length + 1)
        passwordData.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            responseBuf.initialize(from: baseAddress, count: length)
        }
        responseBuf[length] = 0

        responses[i].text = responseBuf
        responses[i].length = UInt32(length)
    }
}

// MARK: - SSH Session using libssh2

actor SSHSession {
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
    private let driver: any LibSSH2SessionDriving
    private var libssh2Session: OpaquePointer?
    private var sftpSession: OpaquePointer?
    private var shellChannels: [UUID: ShellChannelState] = [:]
    private var socket: Int32 = -1
    private var isActive = false
    private var ioTask: Task<Void, Never>?
    private var execRequests: [UUID: ExecRequest] = [:]
    private var connectedPeerAddress: String?
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VVTerm", category: "SSHSession")

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
                logger.debug("libssh2 session free returned \(freeResult)")
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

    // MARK: - Remote Files

    func listDirectory(at path: String, maxEntries: Int? = nil) async throws -> [RemoteFileEntry] {
        let sftp = try await ensureSFTPSession()
        let normalizedPath = RemoteFilePath.normalize(path)
        let handle = try await openDirectoryHandle(at: normalizedPath, sftp: sftp)
        defer { libssh2_sftp_close_handle(handle) }

        let limit = maxEntries ?? .max
        var entries: [RemoteFileEntry] = []
        var nameBuffer = [CChar](repeating: 0, count: 4096)

        while entries.count < limit {
            try Task.checkCancellation()
            var attributes = LIBSSH2_SFTP_ATTRIBUTES()

            let bytesRead = nameBuffer.withUnsafeMutableBufferPointer { buffer -> Int in
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

            if bytesRead > 0 {
                let name = Self.string(from: nameBuffer, length: bytesRead)
                guard name != "." && name != ".." else { continue }

                let entryPath = RemoteFilePath.appending(name, to: normalizedPath)
                let baseEntry = RemoteFileEntry.from(
                    name: name,
                    path: entryPath,
                    attributes: attributes
                )
                let symlinkTarget = baseEntry.type == .symlink ? (try? await readlink(at: entryPath)) : nil
                entries.append(
                    RemoteFileEntry.from(
                        name: name,
                        path: entryPath,
                        attributes: attributes,
                        symlinkTarget: symlinkTarget
                    )
                )
                continue
            }

            if bytesRead == 0 {
                break
            }

            if bytesRead == Int(LIBSSH2_ERROR_EAGAIN) {
                await waitForSocket()
                continue
            }

            throw Self.remoteFileError(from: sftp, operation: "read directory", path: normalizedPath)
        }

        return entries
    }

    func stat(at path: String) async throws -> RemoteFileEntry {
        try await stat(at: path, statType: Int32(LIBSSH2_SFTP_STAT))
    }

    func lstat(at path: String) async throws -> RemoteFileEntry {
        try await stat(at: path, statType: Int32(LIBSSH2_SFTP_LSTAT))
    }

    func readlink(at path: String) async throws -> String {
        let sftp = try await ensureSFTPSession()
        return try await readSymlinkTarget(at: path, linkType: Int32(LIBSSH2_SFTP_READLINK), sftp: sftp)
    }

    func readFile(at path: String, maxBytes: Int, offset: UInt64 = 0) async throws -> Data {
        guard maxBytes > 0 else { return Data() }

        let sftp = try await ensureSFTPSession()
        let normalizedPath = RemoteFilePath.normalize(path)
        let handle = try await openFileHandle(
            at: normalizedPath,
            sftp: sftp,
            flags: UInt32(LIBSSH2_FXF_READ),
            mode: 0
        )
        defer { libssh2_sftp_close_handle(handle) }

        if offset > 0 {
            libssh2_sftp_seek64(handle, offset)
        }

        var data = Data()
        data.reserveCapacity(min(maxBytes, 32 * 1024))

        while data.count < maxBytes {
            try Task.checkCancellation()
            let remaining = maxBytes - data.count
            let chunkSize = min(32 * 1024, remaining)
            var buffer = [CChar](repeating: 0, count: chunkSize)

            let bytesRead = buffer.withUnsafeMutableBufferPointer { bufferPtr -> Int in
                guard let baseAddress = bufferPtr.baseAddress else {
                    return Int(LIBSSH2_ERROR_EAGAIN)
                }
                return Int(libssh2_sftp_read(handle, baseAddress, bufferPtr.count))
            }

            if bytesRead > 0 {
                buffer.withUnsafeBufferPointer { bufferPtr in
                    guard let baseAddress = bufferPtr.baseAddress else { return }
                    data.append(Data(bytes: UnsafeRawPointer(baseAddress), count: bytesRead))
                }
                continue
            }

            if bytesRead == 0 {
                break
            }

            if bytesRead == Int(LIBSSH2_ERROR_EAGAIN) {
                await waitForSocket()
                continue
            }

            throw Self.remoteFileError(from: sftp, operation: "read file", path: normalizedPath)
        }

        return data
    }

    func downloadFile(at path: String, to localURL: URL) async throws {
        let sftp = try await ensureSFTPSession()
        let normalizedPath = RemoteFilePath.normalize(path)
        let handle = try await openFileHandle(
            at: normalizedPath,
            sftp: sftp,
            flags: UInt32(LIBSSH2_FXF_READ),
            mode: 0
        )
        defer { libssh2_sftp_close_handle(handle) }

        let fileManager = FileManager.default
        let destinationDirectory = localURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: localURL.path) {
            try fileManager.removeItem(at: localURL)
        }
        guard fileManager.createFile(atPath: localURL.path, contents: nil) else {
            throw RemoteFileBrowserError.failed(String(localized: "Unable to create the local download file."))
        }

        let localFileHandle = try FileHandle(forWritingTo: localURL)
        do {
            while true {
                try Task.checkCancellation()
                var buffer = [UInt8](repeating: 0, count: 64 * 1024)

                let bytesRead = buffer.withUnsafeMutableBufferPointer { bufferPtr -> Int in
                    guard let baseAddress = bufferPtr.baseAddress else {
                        return Int(LIBSSH2_ERROR_EAGAIN)
                    }
                    return Int(
                        libssh2_sftp_read(
                            handle,
                            UnsafeMutableRawPointer(baseAddress).assumingMemoryBound(to: CChar.self),
                            bufferPtr.count
                        )
                    )
                }

                if bytesRead > 0 {
                    try localFileHandle.write(contentsOf: Data(buffer.prefix(bytesRead)))
                    continue
                }

                if bytesRead == 0 {
                    break
                }

                if bytesRead == Int(LIBSSH2_ERROR_EAGAIN) {
                    await waitForSocket()
                    continue
                }

                throw Self.remoteFileError(from: sftp, operation: "download file", path: normalizedPath)
            }
        } catch {
            try? localFileHandle.close()
            try? fileManager.removeItem(at: localURL)
            throw error
        }

        try localFileHandle.close()
    }

    func writeFile(_ data: Data, to path: String, permissions: Int32 = 0o644) async throws {
        let sftp = try await ensureSFTPSession()
        let normalizedPath = RemoteFilePath.normalize(path)
        let handle = try await openFileHandle(
            at: normalizedPath,
            sftp: sftp,
            flags: UInt32(LIBSSH2_FXF_WRITE | LIBSSH2_FXF_TRUNC | LIBSSH2_FXF_CREAT),
            mode: permissions,
            operation: "write file"
        )
        defer { libssh2_sftp_close_handle(handle) }

        var totalBytesWritten = 0
        while totalBytesWritten < data.count {
            try Task.checkCancellation()

            let bytesWritten = data.withUnsafeBytes { rawBuffer -> Int in
                guard let baseAddress = rawBuffer.baseAddress else { return 0 }
                let remainingCount = min(64 * 1024, data.count - totalBytesWritten)
                let writeBaseAddress = baseAddress
                    .advanced(by: totalBytesWritten)
                    .assumingMemoryBound(to: CChar.self)
                return Int(libssh2_sftp_write(handle, writeBaseAddress, remainingCount))
            }

            if bytesWritten > 0 {
                totalBytesWritten += bytesWritten
                continue
            }

            if bytesWritten == Int(LIBSSH2_ERROR_EAGAIN) {
                await waitForSocket()
                continue
            }

            throw Self.remoteFileError(from: sftp, operation: "write file", path: normalizedPath)
        }
    }

    func resolveHomeDirectory() async throws -> String {
        let sftp = try await ensureSFTPSession()
        let path = try await readSymlinkTarget(at: ".", linkType: Int32(LIBSSH2_SFTP_REALPATH), sftp: sftp)
        return path.isEmpty ? "/" : path
    }

    func fileSystemStatus(at path: String) async throws -> RemoteFileFilesystemStatus {
        let sftp = try await ensureSFTPSession()
        let normalizedPath = RemoteFilePath.normalize(path)
        var status = LIBSSH2_SFTP_STATVFS()

        while true {
            try Task.checkCancellation()

            let result = normalizedPath.withCString { pathPtr in
                libssh2_sftp_statvfs(
                    sftp,
                    pathPtr,
                    normalizedPath.utf8.count,
                    &status
                )
            }

            if result == 0 {
                let fragmentSize = UInt64(status.f_frsize)
                let blockSize = fragmentSize > 0 ? fragmentSize : UInt64(status.f_bsize)
                return RemoteFileFilesystemStatus(
                    blockSize: blockSize,
                    totalBlocks: UInt64(status.f_blocks),
                    freeBlocks: UInt64(status.f_bfree),
                    availableBlocks: UInt64(status.f_bavail)
                )
            }

            if result == Int32(LIBSSH2_ERROR_EAGAIN) {
                await waitForSocket()
                continue
            }

            throw Self.remoteFileError(from: sftp, operation: "read filesystem status", path: normalizedPath)
        }
    }

    func createDirectory(at path: String, permissions: Int32 = 0o755) async throws {
        let sftp = try await ensureSFTPSession()
        let normalizedPath = RemoteFilePath.normalize(path)
        try await performSFTPMutation(
            at: normalizedPath,
            sftp: sftp,
            operation: "create directory"
        ) { sftpHandle, pathPtr, pathLength in
            Int(
                libssh2_sftp_mkdir_ex(
                    sftpHandle,
                    pathPtr,
                    pathLength,
                    Int(permissions)
                )
            )
        }
    }

    func setPermissions(at path: String, permissions: UInt32) async throws {
        let sftp = try await ensureSFTPSession()
        let normalizedPath = RemoteFilePath.normalize(path)
        var attributes = LIBSSH2_SFTP_ATTRIBUTES()
        attributes.flags = UInt(LIBSSH2_SFTP_ATTR_PERMISSIONS)
        attributes.permissions = UInt(permissions)

        while true {
            try Task.checkCancellation()

            let result = normalizedPath.withCString { pathPtr in
                libssh2_sftp_stat_ex(
                    sftp,
                    pathPtr,
                    UInt32(normalizedPath.utf8.count),
                    Int32(LIBSSH2_SFTP_SETSTAT),
                    &attributes
                )
            }

            if result == 0 {
                return
            }

            if result == Int32(LIBSSH2_ERROR_EAGAIN) {
                await waitForSocket()
                continue
            }

            throw Self.remoteFileError(from: sftp, operation: "set permissions", path: normalizedPath)
        }
    }

    func renameItem(at sourcePath: String, to destinationPath: String) async throws {
        let sftp = try await ensureSFTPSession()
        let normalizedSource = RemoteFilePath.normalize(sourcePath)
        let normalizedDestination = RemoteFilePath.normalize(destinationPath)
        let renameFlagCandidates: [Int] = [
            Int(LIBSSH2_SFTP_RENAME_OVERWRITE) |
                Int(LIBSSH2_SFTP_RENAME_ATOMIC) |
                Int(LIBSSH2_SFTP_RENAME_NATIVE),
            Int(LIBSSH2_SFTP_RENAME_OVERWRITE) |
                Int(LIBSSH2_SFTP_RENAME_NATIVE),
            Int(LIBSSH2_SFTP_RENAME_OVERWRITE),
            0
        ]

        var lastError: Error?

        for flags in renameFlagCandidates {
            do {
                try await performSFTPMutation(
                    at: normalizedSource,
                    sftp: sftp,
                    operation: "rename"
                ) { sftpHandle, sourcePtr, sourceLength in
                    normalizedDestination.withCString { destinationPtr in
                        Int(
                            libssh2_sftp_rename_ex(
                                sftpHandle,
                                sourcePtr,
                                sourceLength,
                                destinationPtr,
                                UInt32(normalizedDestination.utf8.count),
                                flags
                            )
                        )
                    }
                }
                return
            } catch {
                lastError = error
            }
        }

        throw lastError ?? RemoteFileBrowserError.failed(String(localized: "Failed to rename item."))
    }

    func deleteFile(at path: String) async throws {
        let sftp = try await ensureSFTPSession()
        let normalizedPath = RemoteFilePath.normalize(path)
        try await performSFTPMutation(
            at: normalizedPath,
            sftp: sftp,
            operation: "delete file"
        ) { sftpHandle, pathPtr, pathLength in
            Int(
                libssh2_sftp_unlink_ex(
                    sftpHandle,
                    pathPtr,
                    pathLength
                )
            )
        }
    }

    func deleteDirectory(at path: String) async throws {
        let sftp = try await ensureSFTPSession()
        let normalizedPath = RemoteFilePath.normalize(path)
        try await performSFTPMutation(
            at: normalizedPath,
            sftp: sftp,
            operation: "delete directory"
        ) { sftpHandle, pathPtr, pathLength in
            Int(
                libssh2_sftp_rmdir_ex(
                    sftpHandle,
                    pathPtr,
                    pathLength
                )
            )
        }
    }

    // MARK: - Shell

    private func logChannelFailure(
        session: OpaquePointer,
        operation: LibSSH2RawError.Operation,
        fallbackCode: Int32
    ) {
        let rawError = driver.lastError(session: session, operation: operation, fallbackCode: fallbackCode)
        logger.debug(
            "libssh2 \(operation.rawValue) returned \(rawError.code) [message: \(rawError.message ?? "none", privacy: .public)]"
        )
    }

    private func closeAndFreeChannel(_ channel: OpaquePointer) {
        let closeResult = driver.closeChannel(channel)
        if closeResult != 0, closeResult != LIBSSH2_ERROR_EAGAIN {
            logger.debug("libssh2 channel close returned \(closeResult)")
        }

        let freeResult = driver.freeChannel(channel)
        if freeResult != 0, freeResult != LIBSSH2_ERROR_EAGAIN {
            logger.debug("libssh2 channel free returned \(freeResult)")
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
                Task { [weak self] in
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
                    // Use _ex variant since macros not available in Swift (stream_id 0 = stdout)
                    let bytesRead = libssh2_channel_read_ex(state.channel, 0, &buffer, buffer.count)

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
                    if libssh2_channel_eof(state.channel) != 0 {
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

                    let bytesRead = libssh2_channel_read_ex(execChannel, 0, &buffer, buffer.count)
                    if bytesRead > 0 {
                        request.output.append(Data(bytes: buffer, count: Int(bytesRead)))
                        didWork = true
                    } else if bytesRead == Int(LIBSSH2_ERROR_EAGAIN) {
                        // No data yet
                    } else if bytesRead < 0 {
                        finishExecRequest(requestId, error: SSHError.socketError("Exec read failed: \(bytesRead)"))
                        continue
                    }

                    let stderrRead = libssh2_channel_read_ex(execChannel, 1, &buffer, buffer.count)
                    if stderrRead > 0 {
                        request.stderr.append(Data(bytes: buffer, count: Int(stderrRead)))
                        didWork = true
                    } else if stderrRead == Int(LIBSSH2_ERROR_EAGAIN) {
                        // No stderr data yet
                    } else if stderrRead < 0 {
                        finishExecRequest(requestId, error: SSHError.socketError("Exec stderr read failed: \(stderrRead)"))
                        continue
                    }

                    if let currentChannel = request.channel, libssh2_channel_eof(currentChannel) != 0 {
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

    private func closeShellInternal(_ shellId: UUID) {
        guard let state = shellChannels.removeValue(forKey: shellId) else { return }
        if !state.batchBuffer.isEmpty {
            state.continuation.yield(state.batchBuffer)
        }
        closeAndFreeChannel(state.channel)
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
            let newChannel = libssh2_channel_open_ex(
                session,
                "session",
                UInt32("session".utf8.count),
                2 * 1024 * 1024,
                32768,
                nil,
                0
            )
            if let newChannel = newChannel {
                request.channel = newChannel
            } else {
                let lastError = libssh2_session_last_errno(session)
                if lastError == LIBSSH2_ERROR_EAGAIN {
                    return false
                }
                finishExecRequest(request.id, error: SSHError.channelOpenFailed)
                return false
            }
        }

        if !request.isStarted, let execChannel = request.channel {
            let execResult = libssh2_channel_process_startup(
                execChannel,
                "exec",
                4,
                request.command,
                UInt32(request.command.utf8.count)
            )
            if execResult == Int32(LIBSSH2_ERROR_EAGAIN) {
                return false
            }
            if execResult != 0 {
                finishExecRequest(request.id, error: SSHError.unknown("Exec failed: \(execResult)"))
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

    private func waitForSocket() async {
        guard let session = libssh2Session, socket >= 0 else { return }

        let direction = libssh2_session_block_directions(session)
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

        // Copy data to array for async-safe access (withUnsafeBytes doesn't support async)
        var bytes = [UInt8](data)
        var remaining = bytes.count
        var offset = 0

        while remaining > 0 {
            // Use _ex variant since macros not available in Swift (stream_id 0 = stdin)
            let written = bytes.withUnsafeMutableBufferPointer { buffer -> Int in
                guard let ptr = buffer.baseAddress else { return -1 }
                return Int(libssh2_channel_write_ex(
                    state.channel, 0,
                    UnsafeRawPointer(ptr.advanced(by: offset)).assumingMemoryBound(to: CChar.self),
                    remaining
                ))
            }

            if written > 0 {
                offset += written
                remaining -= written
            } else if written == Int(LIBSSH2_ERROR_EAGAIN) {
                // Would block - actually wait for socket to be ready
                await waitForSocket()
            } else {
                throw SSHError.socketError("Write failed: \(written)")
            }
        }
    }

    func upload(
        _ data: Data,
        to remotePath: String,
        permissions: Int32 = 0o600,
        strategy: SSHUploadStrategy = .automatic
    ) async throws {
        if strategy == .execPreferred {
            logger.info("Using exec-preferred upload strategy [path: \(remotePath, privacy: .public)]")
            try await uploadViaExec(data, to: remotePath)
            return
        }

        do {
            logger.info("Trying SCP upload [path: \(remotePath, privacy: .public)]")
            try await uploadViaSCP(data, to: remotePath, permissions: permissions)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            logger.warning("SCP upload failed, retrying with exec channel: \(error.localizedDescription, privacy: .public)")
            try await uploadViaExec(data, to: remotePath)
        }
    }

    private func uploadViaSCP(_ data: Data, to remotePath: String, permissions: Int32) async throws {
        guard let session = libssh2Session else {
            throw SSHError.notConnected
        }
        guard !remotePath.isEmpty else {
            throw SSHError.unknown("Upload path is empty")
        }
        logger.info("Opening SCP upload channel [path: \(remotePath, privacy: .public)]")

        var scpChannel: OpaquePointer?
        do {
            while scpChannel == nil {
                try Task.checkCancellation()
                scpChannel = remotePath.withCString { pathPtr in
                    libssh2_scp_send64(
                        session,
                        pathPtr,
                        permissions,
                        Int64(data.count),
                        0,
                        0
                    )
                }

                if scpChannel != nil {
                    break
                }

                let lastError = libssh2_session_last_errno(session)
                if lastError == LIBSSH2_ERROR_EAGAIN {
                    await waitForSocket()
                    continue
                }
                throw SSHError.socketError("SCP channel open failed: \(lastError)")
            }

            guard let scpChannel else {
                throw SSHError.socketError("SCP channel open failed")
            }

            let bytes = [UInt8](data)
            var offset = 0
            while offset < bytes.count {
                try Task.checkCancellation()
                let written = bytes.withUnsafeBufferPointer { buffer -> Int in
                    guard let baseAddress = buffer.baseAddress else { return -1 }
                    let pointer = UnsafeRawPointer(baseAddress.advanced(by: offset)).assumingMemoryBound(to: CChar.self)
                    return Int(libssh2_channel_write_ex(scpChannel, 0, pointer, bytes.count - offset))
                }

                if written > 0 {
                    offset += written
                } else if written == Int(LIBSSH2_ERROR_EAGAIN) {
                    await waitForSocket()
                } else {
                    throw SSHError.socketError("SCP write failed: \(written)")
                }
            }

            _ = try await finishUploadChannel(scpChannel)
            logger.info("SCP upload finished [path: \(remotePath, privacy: .public)]")
        } catch {
            if let scpChannel {
                libssh2_channel_close(scpChannel)
                libssh2_channel_free(scpChannel)
            }
            throw error
        }
    }

    private func uploadViaExec(_ data: Data, to remotePath: String) async throws {
        guard let session = libssh2Session else {
            throw SSHError.notConnected
        }
        guard !remotePath.isEmpty else {
            throw SSHError.unknown("Upload path is empty")
        }
        logger.info("Opening exec upload channel [path: \(remotePath, privacy: .public)]")

        let command = "cat > \(RemoteTerminalBootstrap.shellQuoted(remotePath))"

        var execChannel: OpaquePointer?
        do {
            while execChannel == nil {
                try Task.checkCancellation()
                execChannel = libssh2_channel_open_ex(
                    session,
                    "session",
                    UInt32("session".utf8.count),
                    2 * 1024 * 1024,
                    32768,
                    nil,
                    0
                )

                if execChannel != nil {
                    break
                }

                let lastError = libssh2_session_last_errno(session)
                if lastError == LIBSSH2_ERROR_EAGAIN {
                    await waitForSocket()
                    continue
                }
                throw SSHError.socketError("Exec upload channel open failed: \(lastError)")
            }

            guard let execChannel else {
                throw SSHError.socketError("Exec upload channel open failed")
            }

            _ = libssh2_channel_handle_extended_data2(
                execChannel,
                LIBSSH2_CHANNEL_EXTENDED_DATA_IGNORE
            )

            while true {
                try Task.checkCancellation()
                let execResult = libssh2_channel_process_startup(
                    execChannel,
                    "exec",
                    4,
                    command,
                    UInt32(command.utf8.count)
                )
                if execResult == 0 {
                    break
                }
                if execResult == Int32(LIBSSH2_ERROR_EAGAIN) {
                    await waitForSocket()
                    continue
                }
                throw SSHError.socketError("Exec upload startup failed: \(execResult)")
            }

            let bytes = [UInt8](data)
            var offset = 0
            while offset < bytes.count {
                try Task.checkCancellation()
                let written = bytes.withUnsafeBufferPointer { buffer -> Int in
                    guard let baseAddress = buffer.baseAddress else { return -1 }
                    let pointer = UnsafeRawPointer(baseAddress.advanced(by: offset)).assumingMemoryBound(to: CChar.self)
                    return Int(libssh2_channel_write_ex(execChannel, 0, pointer, bytes.count - offset))
                }

                if written > 0 {
                    offset += written
                } else if written == Int(LIBSSH2_ERROR_EAGAIN) {
                    await waitForSocket()
                } else {
                    throw SSHError.socketError("Exec upload write failed: \(written)")
                }
            }

            let exitStatus = try await finishUploadChannel(execChannel, drainOutput: true)
            guard exitStatus == 0 else {
                throw SSHError.socketError("Exec upload failed with exit status \(exitStatus)")
            }
            logger.info("Exec upload finished [path: \(remotePath, privacy: .public)]")
        } catch {
            if let execChannel {
                libssh2_channel_close(execChannel)
                libssh2_channel_free(execChannel)
            }
            throw error
        }
    }

    private func finishUploadChannel(
        _ channel: OpaquePointer,
        drainOutput: Bool = false
    ) async throws -> Int32 {
        while true {
            try Task.checkCancellation()
            let sendEOFResult = libssh2_channel_send_eof(channel)
            if sendEOFResult == 0 {
                break
            }
            if sendEOFResult == Int32(LIBSSH2_ERROR_EAGAIN) {
                await waitForSocket()
                continue
            }
            throw SSHError.socketError("SCP send EOF failed: \(sendEOFResult)")
        }

        while true {
            try Task.checkCancellation()
            if drainOutput {
                try await drainChannelOutput(channel)
            }
            let waitEOFResult = libssh2_channel_wait_eof(channel)
            if waitEOFResult == 0 {
                break
            }
            if waitEOFResult == Int32(LIBSSH2_ERROR_EAGAIN) {
                await waitForSocket()
                continue
            }
            throw SSHError.socketError("SCP wait EOF failed: \(waitEOFResult)")
        }

        while true {
            try Task.checkCancellation()
            let closeResult = libssh2_channel_close(channel)
            if closeResult == 0 {
                break
            }
            if closeResult == Int32(LIBSSH2_ERROR_EAGAIN) {
                await waitForSocket()
                continue
            }
            throw SSHError.socketError("SCP close failed: \(closeResult)")
        }

        while true {
            try Task.checkCancellation()
            let waitClosedResult = libssh2_channel_wait_closed(channel)
            if waitClosedResult == 0 {
                break
            }
            if waitClosedResult == Int32(LIBSSH2_ERROR_EAGAIN) {
                await waitForSocket()
                continue
            }
            throw SSHError.socketError("SCP wait close failed: \(waitClosedResult)")
        }

        let exitStatus = libssh2_channel_get_exit_status(channel)
        libssh2_channel_free(channel)
        return exitStatus
    }

    private func drainChannelOutput(_ channel: OpaquePointer) async throws {
        var buffer = [CChar](repeating: 0, count: 4096)

        while true {
            try Task.checkCancellation()
            let stdoutRead = libssh2_channel_read_ex(channel, 0, &buffer, buffer.count)
            if stdoutRead > 0 {
                continue
            }
            if stdoutRead == Int(LIBSSH2_ERROR_EAGAIN) || stdoutRead == 0 {
                break
            }
            throw SSHError.socketError("Exec upload stdout drain failed: \(stdoutRead)")
        }

        while true {
            try Task.checkCancellation()
            let stderrRead = libssh2_channel_read_ex(channel, 1, &buffer, buffer.count)
            if stderrRead > 0 {
                continue
            }
            if stderrRead == Int(LIBSSH2_ERROR_EAGAIN) || stderrRead == 0 {
                break
            }
            throw SSHError.socketError("Exec upload stderr drain failed: \(stderrRead)")
        }
    }

    // MARK: - Resize

    func resize(cols: Int, rows: Int, for shellId: UUID) async throws {
        guard let state = shellChannels[shellId] else {
            throw SSHError.notConnected
        }

        // Use _ex variant since macros not available in Swift
        let result = libssh2_channel_request_pty_size_ex(state.channel, Int32(cols), Int32(rows), 0, 0)
        if result != 0 && result != Int32(LIBSSH2_ERROR_EAGAIN) {
            logger.warning("PTY resize failed: \(result)")
        }
    }

    // MARK: - Execute Command

    func execute(_ command: String) async throws -> String {
        guard libssh2Session != nil else {
            throw SSHError.notConnected
        }
        startIOLoop()

        let requestId = UUID()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                let request = ExecRequest(id: requestId, command: command, continuation: continuation)
                execRequests[request.id] = request
            }
        }, onCancel: { [weak self] in
            Task {
                await self?.cancelExecRequest(requestId, error: CancellationError())
            }
        })
    }

    // MARK: - Keep Alive

    func sendKeepAlive() {
        guard let session = libssh2Session else { return }
        var secondsToNext: Int32 = 0
        libssh2_keepalive_send(session, &secondsToNext)
    }

    private func ensureSFTPSession() async throws -> OpaquePointer {
        if let sftpSession {
            return sftpSession
        }

        guard let session = libssh2Session else {
            throw RemoteFileBrowserError.disconnected
        }

        while true {
            try Task.checkCancellation()

            if let sftpSession = libssh2_sftp_init(session) {
                self.sftpSession = sftpSession
                return sftpSession
            }

            let lastError = libssh2_session_last_errno(session)
            if lastError == LIBSSH2_ERROR_EAGAIN {
                await waitForSocket()
                continue
            }

            throw Self.remoteFileError(from: nil, operation: "start SFTP session", path: nil)
        }
    }

    private func openDirectoryHandle(at path: String, sftp: OpaquePointer) async throws -> OpaquePointer {
        try await openSFTPHandle(
            at: path,
            sftp: sftp,
            flags: 0,
            mode: 0,
            openType: Int32(LIBSSH2_SFTP_OPENDIR),
            operation: "open directory"
        )
    }

    private func openFileHandle(
        at path: String,
        sftp: OpaquePointer,
        flags: UInt32,
        mode: Int32,
        operation: String = "open file"
    ) async throws -> OpaquePointer {
        try await openSFTPHandle(
            at: path,
            sftp: sftp,
            flags: flags,
            mode: mode,
            openType: Int32(LIBSSH2_SFTP_OPENFILE),
            operation: operation
        )
    }

    private func openSFTPHandle(
        at path: String,
        sftp: OpaquePointer,
        flags: UInt32,
        mode: Int32,
        openType: Int32,
        operation: String
    ) async throws -> OpaquePointer {
        guard let session = libssh2Session else {
            throw RemoteFileBrowserError.disconnected
        }

        let pathLength = UInt32(path.utf8.count)
        while true {
            try Task.checkCancellation()

            if let handle = path.withCString({ pathPtr in
                libssh2_sftp_open_ex(
                    sftp,
                    pathPtr,
                    pathLength,
                    UInt(flags),
                    Int(mode),
                    Int32(openType)
                )
            }) {
                return handle
            }

            let lastError = libssh2_session_last_errno(session)
            if lastError == LIBSSH2_ERROR_EAGAIN {
                await waitForSocket()
                continue
            }

            throw Self.remoteFileError(from: sftp, operation: operation, path: path)
        }
    }

    private func performSFTPMutation(
        at path: String,
        sftp: OpaquePointer,
        operation: String,
        mutation: (OpaquePointer, UnsafePointer<CChar>, UInt32) -> Int
    ) async throws {
        guard libssh2Session != nil else {
            throw RemoteFileBrowserError.disconnected
        }

        let pathLength = UInt32(path.utf8.count)
        while true {
            try Task.checkCancellation()

            let result = path.withCString { pathPtr in
                mutation(sftp, pathPtr, pathLength)
            }

            if result == 0 {
                return
            }

            if result == Int(LIBSSH2_ERROR_EAGAIN) {
                await waitForSocket()
                continue
            }

            throw Self.remoteFileError(from: sftp, operation: operation, path: path)
        }
    }

    private func stat(at path: String, statType: Int32) async throws -> RemoteFileEntry {
        let sftp = try await ensureSFTPSession()
        let normalizedPath = RemoteFilePath.normalize(path)
        var attributes = LIBSSH2_SFTP_ATTRIBUTES()

        while true {
            try Task.checkCancellation()

            let result = normalizedPath.withCString { pathPtr in
                libssh2_sftp_stat_ex(
                    sftp,
                    pathPtr,
                    UInt32(normalizedPath.utf8.count),
                    statType,
                    &attributes
                )
            }

            if result == 0 {
                let entryName = Self.fileName(for: normalizedPath)
                var symlinkTarget: String?
                let entry = RemoteFileEntry.from(name: entryName, path: normalizedPath, attributes: attributes)
                if statType == Int32(LIBSSH2_SFTP_LSTAT), entry.type == .symlink {
                    symlinkTarget = try? await readlink(at: normalizedPath)
                }
                return RemoteFileEntry.from(
                    name: entryName,
                    path: normalizedPath,
                    attributes: attributes,
                    symlinkTarget: symlinkTarget
                )
            }

            if result == Int32(LIBSSH2_ERROR_EAGAIN) {
                await waitForSocket()
                continue
            }

            throw Self.remoteFileError(
                from: sftp,
                operation: statType == Int32(LIBSSH2_SFTP_LSTAT) ? "lstat" : "stat",
                path: normalizedPath
            )
        }
    }

    private func readSymlinkTarget(
        at path: String,
        linkType: Int32,
        sftp: OpaquePointer
    ) async throws -> String {
        guard let session = libssh2Session else {
            throw RemoteFileBrowserError.disconnected
        }

        let requestPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPath = requestPath.isEmpty ? "." : requestPath
        var buffer = [CChar](repeating: 0, count: 4096)

        while true {
            try Task.checkCancellation()

            let result = buffer.withUnsafeMutableBufferPointer { bufferPtr -> Int in
                guard let baseAddress = bufferPtr.baseAddress else {
                    return Int(LIBSSH2_ERROR_EAGAIN)
                }

                return normalizedPath.withCString { pathPtr in
                    Int(
                        libssh2_sftp_symlink_ex(
                            sftp,
                            pathPtr,
                            UInt32(normalizedPath.utf8.count),
                            baseAddress,
                            UInt32(bufferPtr.count),
                            linkType
                        )
                    )
                }
            }

            if result >= 0 {
                return Self.string(from: buffer, length: result)
            }

            let lastError = libssh2_session_last_errno(session)
            if lastError == LIBSSH2_ERROR_EAGAIN {
                await waitForSocket()
                continue
            }

            throw Self.remoteFileError(
                from: sftp,
                operation: linkType == Int32(LIBSSH2_SFTP_REALPATH) ? "resolve path" : "read link",
                path: normalizedPath
            )
        }
    }

    private func closeSFTPSession() {
        guard let sftpSession else { return }
        _ = libssh2_sftp_shutdown(sftpSession)
        self.sftpSession = nil
    }

    private static func fileName(for path: String) -> String {
        let normalized = RemoteFilePath.normalize(path)
        guard normalized != "/" else { return "/" }
        return normalized.split(separator: "/").last.map(String.init) ?? normalized
    }

    private static func string(from buffer: [CChar], length: Int) -> String {
        let bytes = buffer.prefix(length).map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func remoteFileError(
        from sftp: OpaquePointer?,
        operation: String,
        path: String?
    ) -> RemoteFileBrowserError {
        let code = sftp.map { libssh2_sftp_last_error($0) } ?? 0
        return remoteFileError(lastError: UInt(code), operation: operation, path: path)
    }

    private static func remoteFileError(
        lastError: UInt,
        operation: String,
        path: String?
    ) -> RemoteFileBrowserError {
        switch lastError {
        case UInt(LIBSSH2_FX_PERMISSION_DENIED):
            return .permissionDenied
        case UInt(LIBSSH2_FX_NO_SUCH_FILE), UInt(LIBSSH2_FX_NO_SUCH_PATH):
            return .pathNotFound
        case UInt(LIBSSH2_FX_NO_CONNECTION), UInt(LIBSSH2_FX_CONNECTION_LOST):
            return .disconnected
        case UInt(LIBSSH2_FX_NOT_A_DIRECTORY):
            return .failed(String(localized: "The remote path is not a directory."))
        case UInt(LIBSSH2_FX_LINK_LOOP):
            return .failed(String(localized: "The remote path contains a symbolic link loop."))
        default:
            let location = path.map { " (\($0))" } ?? ""
            return .failed(String(localized: "Failed to \(operation)\(location)."))
        }
    }
}

// MARK: - SSH Session Config

struct SSHSessionConfig {
    let host: String
    let port: Int
    let dialHost: String
    let dialPort: Int
    let hostKeyHost: String
    let hostKeyPort: Int
    let username: String
    let connectionMode: SSHConnectionMode
    let authMethod: AuthMethod
    let credentials: ServerCredentials

    var connectionTimeout: TimeInterval = 30
    var keepAliveInterval: TimeInterval = 30

    init(
        host: String,
        port: Int,
        dialHost: String? = nil,
        dialPort: Int? = nil,
        hostKeyHost: String? = nil,
        hostKeyPort: Int? = nil,
        username: String,
        connectionMode: SSHConnectionMode,
        authMethod: AuthMethod,
        credentials: ServerCredentials,
        connectionTimeout: TimeInterval = 30,
        keepAliveInterval: TimeInterval = 30
    ) {
        self.host = host
        self.port = port
        self.dialHost = dialHost ?? host
        self.dialPort = dialPort ?? port
        self.hostKeyHost = hostKeyHost ?? host
        self.hostKeyPort = hostKeyPort ?? port
        self.username = username
        self.connectionMode = connectionMode
        self.authMethod = authMethod
        self.credentials = credentials
        self.connectionTimeout = connectionTimeout
        self.keepAliveInterval = keepAliveInterval
    }
}

// MARK: - SSH Error

enum SSHError: LocalizedError {
    case notConnected
    case connectionFailed(String)
    case authenticationFailed
    case tailscaleAuthenticationNotAccepted
    case cloudflareConfigurationRequired(String)
    case cloudflareAuthenticationFailed(String)
    case cloudflareTunnelFailed(String)
    case moshServerMissing
    case moshBootstrapFailed(String)
    case moshSessionFailed(String)
    case timeout
    case channelOpenFailed
    case shellRequestFailed
    case hostKeyVerificationFailed
    case socketError(String)
    case libssh2(LibSSH2RawError)
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected to server"
        case .connectionFailed(let msg): return "Connection failed: \(msg)"
        case .authenticationFailed: return "Authentication failed"
        case .tailscaleAuthenticationNotAccepted:
            return "\(String(localized: "Tailscale SSH authentication was not accepted by the server.")) \(String(localized: "This app currently supports direct tailnet connections only (no userspace proxy fallback)."))"
        case .cloudflareConfigurationRequired(let message):
            return String(format: String(localized: "Cloudflare configuration error: %@"), message)
        case .cloudflareAuthenticationFailed(let message):
            return String(format: String(localized: "Cloudflare authentication failed: %@"), message)
        case .cloudflareTunnelFailed(let message):
            return String(format: String(localized: "Cloudflare tunnel failed: %@"), message)
        case .moshServerMissing:
            return String(localized: "mosh-server is not installed on the remote host")
        case .moshBootstrapFailed(let msg):
            return "Mosh bootstrap failed: \(msg)"
        case .moshSessionFailed(let msg):
            return "Mosh session failed: \(msg)"
        case .timeout: return "Connection timed out"
        case .channelOpenFailed: return "Failed to open channel"
        case .shellRequestFailed: return "Failed to request shell"
        case .hostKeyVerificationFailed:
            return "Host key verification failed. The saved SSH host fingerprint does not match the server's current key."
        case .socketError(let msg): return "Socket error: \(msg)"
        case .libssh2(let error):
            let detail = error.message ?? "code \(error.code)"
            return "libssh2 \(error.operation.rawValue) failed: \(detail)"
        case .unknown(let msg): return "Unknown error: \(msg)"
        }
    }

    /// Whether a connection attempt that failed with this error should be retried.
    /// Auth/host-key/tailscale failures are deterministic — retrying only piles up
    /// failed-auth events and triggers sshd penalty boxing.
    var isRetryable: Bool {
        switch self {
        case .authenticationFailed,
             .hostKeyVerificationFailed,
             .tailscaleAuthenticationNotAccepted:
            return false
        default:
            return true
        }
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

// MARK: - Atomic Socket for Thread-Safe Abort

/// Thread-safe socket storage that allows closing from any thread
final class AtomicSocket: @unchecked Sendable {
    private nonisolated(unsafe) var _socket: Int32 = -1
    private let lock = NSLock()

    nonisolated init() {}

    nonisolated var socket: Int32 {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _socket
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _socket = newValue
        }
    }

    /// Close the socket immediately from any thread
    nonisolated func closeImmediately() {
        lock.lock()
        let sock = _socket
        _socket = -1
        lock.unlock()

        if sock >= 0 {
            Darwin.close(sock)
        }
    }
}
