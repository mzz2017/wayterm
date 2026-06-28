import Foundation
import os.log
import MoshCore
import MoshBootstrap

// MARK: - SSH Client using libssh2

nonisolated actor SSHClient {
    private final class MoshShellRuntime: @unchecked Sendable {
        let session: MoshClientSession
        private let lock = NSLock()
        private var streamTask: Task<Void, Never>?

        init(session: MoshClientSession) {
            self.session = session
        }

        func setStreamTask(_ task: Task<Void, Never>) {
            lock.lock()
            streamTask = task
            lock.unlock()
        }

        func cancelStreamTask() {
            lock.lock()
            let task = streamTask
            streamTask = nil
            lock.unlock()
            task?.cancel()
        }
    }

    private var session: SSHSession?
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VVTerm", category: "SSH")
    private var keepAliveTask: Task<Void, Never>?
    private var connectTask: Task<SSHSession, Error>?
    private var pendingConnectSession: SSHSession?
    private var connectionKey: String?
    private var connectedTarget: SSHConnectionTarget?
    private var resolvedRemoteEnvironment: RemoteEnvironment?
    private var resolvedRemoteTerminalType: RemoteTerminalType?
    private var moshShells: [UUID: MoshShellRuntime] = [:]
    nonisolated private let moshTeardownTasks = SSHMoshTeardownTaskRegistry()
    private let cloudflareTransportManager = CloudflareTransportManager()
    private let moshStartupTimeout: Duration = .seconds(8)
    private let connectTimeout: Duration = .seconds(30)
    private let disconnectTimeout: Duration = .seconds(4)
    private let shellStartTimeout: Duration = .seconds(20)
    private let execTimeout: Duration = .seconds(20)
    private let downloadTimeout: Duration = .seconds(120)
    private let uploadTimeout: Duration = .seconds(60)
    private let abortState = SSHClientAbortState()
    private let sessionFactory: @Sendable (SSHSessionConfig) -> SSHSession

    init(sessionFactory: @escaping @Sendable (SSHSessionConfig) -> SSHSession = { SSHSession(config: $0) }) {
        self.sessionFactory = sessionFactory
    }

    /// Immediately abort the connection by closing the socket (non-blocking, can be called from any thread)
    nonisolated func abort() {
        abortState.abort()
    }

    /// Check if the client has been aborted
    var isAborted: Bool {
        abortState.isAborted
    }

    // MARK: - Connection

    func connect(to target: SSHConnectionTarget, credentials: ServerCredentials) async throws -> SSHSession {
        abortState.reset()
        try Task.checkCancellation()

        let key = target.connectionKey

        if let session = session, await session.isConnected, connectionKey == key {
            connectedTarget = target
            return session
        }

        if let task = connectTask, connectionKey == key {
            let connected = try await task.value
            connectedTarget = target
            return connected
        }

        if let session = session, await session.isConnected, connectionKey != key {
            throw SSHError.connectionFailed("SSH client already connected")
        }

        logger.info("Connecting to \(target.host):\(target.port) [mode: \(target.connectionMode.rawValue)]")
        logger.info("Auth method: \(String(describing: target.authMethod)), password present: \(credentials.password != nil)")

        var dialHost = target.host
        var dialPort = target.port

        if target.connectionMode == .cloudflare {
            let localPort = try await cloudflareTransportManager.connect(target: target, credentials: credentials)
            dialHost = "127.0.0.1"
            dialPort = Int(localPort)
            logger.info("Using Cloudflare local tunnel endpoint \(dialHost):\(dialPort)")
        } else {
            await disconnectCloudflareTransport(reason: "pre-connect cleanup")
        }

        let config = SSHSessionConfig(
            host: target.host,
            port: target.port,
            dialHost: dialHost,
            dialPort: dialPort,
            hostKeyHost: target.host,
            hostKeyPort: target.port,
            username: target.username,
            connectionMode: target.connectionMode,
            authMethod: target.authMethod,
            credentials: credentials
        )

        let pendingSession = sessionFactory(config)
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
            guard isCurrentPendingConnectSession(pendingSession) else {
                session.abort()
                await session.disconnect()
                throw CancellationError()
            }
            pendingConnectSession = nil
            if abortState.isAborted || Task.isCancelled || task.isCancelled {
                session.abort()
                await session.disconnect()
                connectTask = nil
                connectionKey = nil
                self.session = nil
                abortState.setSessionForAbort(nil)
                self.connectedTarget = nil
                await disconnectCloudflareTransport(reason: "connect cancellation")
                throw CancellationError()
            }
            self.session = session
            abortState.setSessionForAbort(session)
            self.connectedTarget = target
            self.resolvedRemoteEnvironment = nil
            self.resolvedRemoteTerminalType = nil
            startKeepAlive()
            connectTask = nil
            logger.info("Connected to \(target.host)")
            return session
        } catch {
            if isCurrentPendingConnectSession(pendingSession) {
                pendingConnectSession = nil
                connectTask = nil
                connectionKey = nil
                self.session = nil
                abortState.setSessionForAbort(nil)
                self.connectedTarget = nil
                self.resolvedRemoteEnvironment = nil
                self.resolvedRemoteTerminalType = nil
                await disconnectCloudflareTransport(reason: "connect failure")
            }
            if target.connectionMode == .cloudflare,
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
            trackMoshTeardownTask {
                runtime.cancelStreamTask()
                await runtime.session.stop()
            }
        }
        await waitForMoshTeardownTasks()

        keepAliveTask?.cancel()
        keepAliveTask = nil

        let pendingConnectTask = connectTask
        let pendingConnectSession = pendingConnectSession
        connectTask = nil
        self.pendingConnectSession = nil
        connectionKey = nil

        let activeSession = session
        session = nil
        abortState.setSessionForAbort(nil)
        connectedTarget = nil
        resolvedRemoteEnvironment = nil
        resolvedRemoteTerminalType = nil

        pendingConnectTask?.cancel()
        pendingConnectSession?.abort()
        _ = await pendingConnectTask?.result

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

    func listDirectory(at path: String, maxEntries: Int? = nil) async throws -> [SSHFileTransferEntry] {
        guard !abortState.isAborted, let session = session else {
            throw SSHFileTransferError.disconnected
        }
        return try await session.listDirectory(at: path, maxEntries: maxEntries)
    }

    func stat(at path: String) async throws -> SSHFileTransferEntry {
        guard !abortState.isAborted, let session = session else {
            throw SSHFileTransferError.disconnected
        }
        return try await session.stat(at: path)
    }

    func lstat(at path: String) async throws -> SSHFileTransferEntry {
        guard !abortState.isAborted, let session = session else {
            throw SSHFileTransferError.disconnected
        }
        return try await session.lstat(at: path)
    }

    func readlink(at path: String) async throws -> String {
        guard !abortState.isAborted, let session = session else {
            throw SSHFileTransferError.disconnected
        }
        return try await session.readlink(at: path)
    }

    func readFile(at path: String, maxBytes: Int, offset: UInt64 = 0) async throws -> Data {
        guard !abortState.isAborted, let session = session else {
            throw SSHFileTransferError.disconnected
        }
        return try await session.readFile(at: path, maxBytes: maxBytes, offset: offset)
    }

    func fileSystemStatus(at path: String) async throws -> SSHFileTransferFilesystemStatus {
        guard !abortState.isAborted, let session = session else {
            throw SSHFileTransferError.disconnected
        }
        return try await session.fileSystemStatus(at: path)
    }

    func downloadFile(at path: String, to localURL: URL) async throws {
        guard !abortState.isAborted, let session = session else {
            throw SSHFileTransferError.disconnected
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
            throw SSHFileTransferError.disconnected
        }
        return try await session.resolveHomeDirectory()
    }

    func createDirectory(at path: String, permissions: Int32 = 0o755) async throws {
        guard !abortState.isAborted, let session = session else {
            throw SSHFileTransferError.disconnected
        }
        try await session.createDirectory(at: path, permissions: permissions)
    }

    func setPermissions(at path: String, permissions: UInt32) async throws {
        guard !abortState.isAborted, let session = session else {
            throw SSHFileTransferError.disconnected
        }
        try await session.setPermissions(at: path, permissions: permissions)
    }

    func renameItem(at sourcePath: String, to destinationPath: String) async throws {
        guard !abortState.isAborted, let session = session else {
            throw SSHFileTransferError.disconnected
        }
        try await session.renameItem(at: sourcePath, to: destinationPath)
    }

    func deleteFile(at path: String) async throws {
        guard !abortState.isAborted, let session = session else {
            throw SSHFileTransferError.disconnected
        }
        try await session.deleteFile(at: path)
    }

    func deleteDirectory(at path: String) async throws {
        guard !abortState.isAborted, let session = session else {
            throw SSHFileTransferError.disconnected
        }
        try await session.deleteDirectory(at: path)
    }

    // MARK: - Shell

    func startShell(cols: Int = 80, rows: Int = 24, startupCommand: String? = nil) async throws -> ShellHandle {
        guard let session = session else {
            throw SSHError.notConnected
        }

        let connectionMode = connectedTarget?.connectionMode ?? .standard
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
            runtime.cancelStreamTask()
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

    private func isCurrentPendingConnectSession(_ pendingSession: SSHSession) -> Bool {
        guard let currentPendingSession = pendingConnectSession else { return false }
        return ObjectIdentifier(currentPendingSession) == ObjectIdentifier(pendingSession)
    }

    private func disconnectSSHSession(_ activeSession: SSHSession?) async {
        guard let activeSession else { return }
        do {
            try await SSHClient.runWithTimeout(
                disconnectTimeout,
                operation: {
                    await activeSession.disconnect()
                },
                onTimeout: {
                    activeSession.abort()
                }
            )
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
        let configuredHost = connectedTarget?.host.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
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
        let runtime = MoshShellRuntime(session: moshSession)
        moshShells[shellId] = runtime
        let stream = AsyncStream<Data> { continuation in
            // Replay any ops that arrived before the stream was created
            for op in pendingOps {
                if case .hostBytes(let bytes) = op {
                    continuation.yield(bytes)
                }
            }
            let streamTask = Task {
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
                await self.closeShell(shellId)
            }
            runtime.setStreamTask(streamTask)

            continuation.onTermination = { _ in
                runtime.cancelStreamTask()
                self.trackMoshTeardownTask {
                    await self.closeShell(shellId)
                }
            }
        }

        return ShellHandle(
            id: shellId,
            stream: stream,
            transport: .mosh
        )
    }

    nonisolated private func trackMoshTeardownTask(_ operation: @escaping @Sendable () async -> Void) {
        moshTeardownTasks.track(operation)
    }

    private func waitForMoshTeardownTasks() async {
        while true {
            let tasks = moshTeardownTasks.tasks()
            guard !tasks.isEmpty else { return }
            for task in tasks {
                await task.value
            }
        }
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
