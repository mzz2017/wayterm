//
//  SSHSession+Channels.swift
//  VVTerm
//
//  libssh2 shell and exec channel runtime.
//

import Foundation
import os.log

nonisolated final class SSHSessionExecRequest: @unchecked Sendable {
    fileprivate let id: UUID
    fileprivate let command: String
    fileprivate let continuation: CheckedContinuation<String, Error>
    fileprivate var channel: OpaquePointer?
    fileprivate var output = Data()
    fileprivate var stderr = Data()
    fileprivate var isStarted = false

    init(id: UUID, command: String, continuation: CheckedContinuation<String, Error>) {
        self.id = id
        self.command = command
        self.continuation = continuation
    }
}

nonisolated final class SSHSessionShellChannelState: @unchecked Sendable {
    fileprivate let id: UUID
    fileprivate var channel: OpaquePointer
    fileprivate let continuation: AsyncStream<Data>.Continuation
    fileprivate var batchBuffer = Data()
    fileprivate var lastYieldTime: UInt64 = DispatchTime.now().uptimeNanoseconds
    fileprivate var recentBytesPerRead: Int = 0

    init(id: UUID, channel: OpaquePointer, continuation: AsyncStream<Data>.Continuation) {
        self.id = id
        self.channel = channel
        self.continuation = continuation
    }
}

extension SSHSession {
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

        // Set blocking for channel setup.
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
            let state = SSHSessionShellChannelState(id: shellId, channel: channel, continuation: continuation)
            self.shellChannels[shellId] = state

            continuation.onTermination = { _ in
                self.trackChannelCleanupTask {
                    await self.closeShell(shellId)
                }
            }
        }

        startIOLoop()

        return ShellHandle(id: shellId, stream: stream)
    }

    func startIOLoop() {
        guard ioTask == nil else { return }
        ioTask = Task { [weak self] in
            await self?.ioLoop()
        }
    }

    func stopIOLoop() {
        ioTask?.cancel()
        ioTask = nil
    }

    func ioLoop() async {
        var buffer = [CChar](repeating: 0, count: 32768)
        let batchThreshold = 65536  // 64KB batch threshold

        // Adaptive batch delay: track data rate to switch between interactive and bulk modes.
        let interactiveDelay: UInt64 = 1_000_000
        let bulkDelay: UInt64 = 5_000_000
        let interactiveThreshold = 100
        let bulkThreshold = 1000

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

                        state.recentBytesPerRead = (state.recentBytesPerRead * 7 + readCount * 3) / 10

                        let maxBatchDelay: UInt64
                        if state.recentBytesPerRead < interactiveThreshold {
                            maxBatchDelay = interactiveDelay
                        } else if state.recentBytesPerRead > bulkThreshold {
                            maxBatchDelay = bulkDelay
                        } else {
                            let ratio = UInt64(state.recentBytesPerRead - interactiveThreshold) * 100 / UInt64(bulkThreshold - interactiveThreshold)
                            maxBatchDelay = interactiveDelay + (bulkDelay - interactiveDelay) * ratio / 100
                        }

                        let now = DispatchTime.now().uptimeNanoseconds
                        let timeSinceYield = now - state.lastYieldTime

                        if state.batchBuffer.count >= batchThreshold || timeSinceYield >= maxBatchDelay {
                            state.continuation.yield(state.batchBuffer)
                            state.batchBuffer = Data()
                            state.lastYieldTime = now
                        }
                    } else if bytesRead == Int(LIBSSH2_ERROR_EAGAIN) {
                        if !state.batchBuffer.isEmpty {
                            state.continuation.yield(state.batchBuffer)
                            state.batchBuffer = Data()
                            state.lastYieldTime = DispatchTime.now().uptimeNanoseconds
                        }
                        state.recentBytesPerRead = 0
                    } else if bytesRead < 0 {
                        if !state.batchBuffer.isEmpty {
                            state.continuation.yield(state.batchBuffer)
                        }
                        logger.error("Read error: \(bytesRead)")
                        closeShellInternal(state.id)
                        continue
                    }

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
                        // No data yet.
                    } else if bytesRead < 0 {
                        finishExecRequest(requestId, error: SSHError.socketError("Exec read failed: \(bytesRead)"))
                        continue
                    }

                    let stderrRead = driver.readChannel(execChannel, stream: 1, into: &buffer)
                    if stderrRead > 0 {
                        request.stderr.append(Data(bytes: buffer, count: Int(stderrRead)))
                        didWork = true
                    } else if stderrRead == Int(LIBSSH2_ERROR_EAGAIN) {
                        // No stderr data yet.
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

            // Yield so writes and UI updates are not starved during rapid output.
            await Task.yield()
        }

        closeAllShellChannels()
        stopIOLoop()
    }

    func closeShell(_ shellId: UUID) async {
        closeShellInternal(shellId)
    }

    nonisolated func trackChannelCleanupTask(_ operation: @escaping @Sendable () async -> Void) {
        channelCleanupTasks.track(operation)
    }

    func waitForChannelCleanupTasks() async {
        while true {
            let tasks = channelCleanupTasks.tasks()
            guard !tasks.isEmpty else { return }
            for task in tasks {
                await task.value
            }
        }
    }

    func closeShellInternal(_ shellId: UUID) {
        guard let state = shellChannels.removeValue(forKey: shellId) else { return }
        if !state.batchBuffer.isEmpty {
            state.continuation.yield(state.batchBuffer)
        }
        closeAndFreeChannel(state.channel)
        state.continuation.onTermination = nil
        state.continuation.finish()
    }

    func closeAllShellChannels() {
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

    func closeAllExecChannels() {
        for request in execRequests.values {
            if let channel = request.channel {
                closeAndFreeChannel(channel)
                request.channel = nil
            }
        }
        execRequests.removeAll()
    }

    func failAllExecRequests(error: Error) {
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

    func ensureExecChannelReady(_ request: SSHSessionExecRequest) -> Bool {
        guard let session = libssh2Session else {
            finishExecRequest(request.id, error: SSHError.notConnected)
            return false
        }

        if request.channel == nil {
            let newChannel = driver.openSessionChannel(session: session)
            if let newChannel {
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

    func cancelExecRequest(_ requestId: UUID, error: Error) {
        guard execRequests[requestId] != nil else { return }
        finishExecRequest(requestId, error: error)
    }

    func finishExecRequest(_ requestId: UUID, error: Error?) {
        guard let request = execRequests.removeValue(forKey: requestId) else { return }

        if let channel = request.channel {
            closeAndFreeChannel(channel)
            request.channel = nil
        }

        if let error {
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

        var pfd = pollfd()
        pfd.fd = socket
        pfd.events = 0

        if direction & LIBSSH2_SESSION_BLOCK_INBOUND != 0 {
            pfd.events |= Int16(POLLIN)
        }
        if direction & LIBSSH2_SESSION_BLOCK_OUTBOUND != 0 {
            pfd.events |= Int16(POLLOUT)
        }

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
                let request = SSHSessionExecRequest(id: requestId, command: command, continuation: continuation)
                execRequests[request.id] = request
                startIOLoop()
            }
        }, onCancel: {
            self.trackChannelCleanupTask {
                await self.cancelExecRequest(requestId, error: CancellationError())
            }
        })
    }
}
