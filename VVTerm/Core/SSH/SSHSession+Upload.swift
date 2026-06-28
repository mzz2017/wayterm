//
//  SSHSession+Upload.swift
//  VVTerm
//
//  Upload strategies for SSHSession.
//

import Foundation
import os

extension SSHSession {
    func upload(
        _ data: Data,
        to remotePath: String,
        permissions: Int32 = 0o600,
        strategy: SSHUploadStrategy = .automatic
    ) async throws {
        switch strategy {
        case .execPreferred:
            logger.info("Using exec-preferred upload strategy [path: \(remotePath, privacy: .public)]")
            try await uploadViaExec(data, to: remotePath)
            return
        case .scpOnly:
            logger.info("Using SCP-only upload strategy [path: \(remotePath, privacy: .public)]")
            try await uploadViaSCP(data, to: remotePath, permissions: permissions)
            return
        case .automatic:
            break
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
                scpChannel = driver.openSCPChannel(
                    session: session,
                    path: remotePath,
                    permissions: permissions,
                    size: Int64(data.count)
                )

                if scpChannel != nil {
                    break
                }

                let rawError = driver.lastError(session: session, operation: .scpChannelOpen, fallbackCode: 0)
                if rawError.code == LIBSSH2_ERROR_EAGAIN {
                    await waitForSocket()
                    continue
                }
                throw SSHError.libssh2(rawError)
            }

            guard let openedSCPChannel = scpChannel else {
                let rawError = driver.lastError(session: session, operation: .scpChannelOpen, fallbackCode: 0)
                throw SSHError.libssh2(rawError)
            }

            let bytes = [UInt8](data)
            var offset = 0
            while offset < bytes.count {
                try Task.checkCancellation()
                let written = driver.writeChannel(
                    openedSCPChannel,
                    stream: 0,
                    bytes: bytes,
                    offset: offset,
                    remaining: bytes.count - offset
                )

                if written > 0 {
                    offset += written
                } else if written == Int(LIBSSH2_ERROR_EAGAIN) {
                    await waitForSocket()
                } else {
                    let rawError = driver.lastError(
                        session: session,
                        operation: .channelWrite,
                        fallbackCode: Int32(written)
                    )
                    throw SSHError.libssh2(rawError)
                }
            }

            _ = try await finishUploadChannel(openedSCPChannel)
            scpChannel = nil
            logger.info("SCP upload finished [path: \(remotePath, privacy: .public)]")
        } catch {
            if let scpChannel {
                closeAndFreeChannel(scpChannel)
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
                execChannel = driver.openSessionChannel(session: session)

                if execChannel != nil {
                    break
                }

                let rawError = driver.lastError(session: session, operation: .channelOpen, fallbackCode: 0)
                if rawError.code == LIBSSH2_ERROR_EAGAIN {
                    await waitForSocket()
                    continue
                }
                throw SSHError.libssh2(rawError)
            }

            guard let openedExecChannel = execChannel else {
                throw SSHError.socketError("Exec upload channel open failed")
            }

            _ = driver.handleExtendedData(
                channel: openedExecChannel,
                mode: LIBSSH2_CHANNEL_EXTENDED_DATA_IGNORE
            )

            while true {
                try Task.checkCancellation()
                let execResult = driver.startExec(channel: openedExecChannel, command: command)
                if execResult == 0 {
                    break
                }
                if execResult == Int32(LIBSSH2_ERROR_EAGAIN) {
                    await waitForSocket()
                    continue
                }
                throw libSSH2Error(
                    session: session,
                    operation: .channelProcessStartup,
                    fallbackCode: execResult
                )
            }

            let bytes = [UInt8](data)
            var offset = 0
            while offset < bytes.count {
                try Task.checkCancellation()
                let written = driver.writeChannel(
                    openedExecChannel,
                    stream: 0,
                    bytes: bytes,
                    offset: offset,
                    remaining: bytes.count - offset
                )

                if written > 0 {
                    offset += written
                } else if written == Int(LIBSSH2_ERROR_EAGAIN) {
                    await waitForSocket()
                } else {
                    throw libSSH2Error(
                        session: session,
                        operation: .channelWrite,
                        fallbackCode: Int32(written)
                    )
                }
            }

            let exitStatus = try await finishUploadChannel(openedExecChannel, drainOutput: true)
            execChannel = nil
            guard exitStatus == 0 else {
                throw SSHError.socketError("Exec upload failed with exit status \(exitStatus)")
            }
            logger.info("Exec upload finished [path: \(remotePath, privacy: .public)]")
        } catch {
            if let execChannel {
                closeAndFreeChannel(execChannel)
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
            let sendEOFResult = driver.sendChannelEOF(channel)
            if sendEOFResult == 0 {
                break
            }
            if sendEOFResult == Int32(LIBSSH2_ERROR_EAGAIN) {
                await waitForSocket()
                continue
            }
            if let session = libssh2Session {
                throw libSSH2Error(
                    session: session,
                    operation: .channelEOF,
                    fallbackCode: sendEOFResult
                )
            }
            throw SSHError.socketError("SCP send EOF failed: \(sendEOFResult)")
        }

        while true {
            try Task.checkCancellation()
            if drainOutput {
                try await drainChannelOutput(channel)
            }
            let waitEOFResult = driver.waitChannelEOF(channel)
            if waitEOFResult == 0 {
                break
            }
            if waitEOFResult == Int32(LIBSSH2_ERROR_EAGAIN) {
                await waitForSocket()
                continue
            }
            if let session = libssh2Session {
                throw libSSH2Error(
                    session: session,
                    operation: .channelWaitEOF,
                    fallbackCode: waitEOFResult
                )
            }
            throw SSHError.socketError("SCP wait EOF failed: \(waitEOFResult)")
        }

        while true {
            try Task.checkCancellation()
            let closeResult = driver.closeChannel(channel)
            if closeResult == 0 {
                break
            }
            if closeResult == Int32(LIBSSH2_ERROR_EAGAIN) {
                await waitForSocket()
                continue
            }
            if let session = libssh2Session {
                throw libSSH2Error(
                    session: session,
                    operation: .channelClose,
                    fallbackCode: closeResult
                )
            }
            throw SSHError.socketError("SCP close failed: \(closeResult)")
        }

        while true {
            try Task.checkCancellation()
            let waitClosedResult = driver.waitChannelClosed(channel)
            if waitClosedResult == 0 {
                break
            }
            if waitClosedResult == Int32(LIBSSH2_ERROR_EAGAIN) {
                await waitForSocket()
                continue
            }
            if let session = libssh2Session {
                throw libSSH2Error(
                    session: session,
                    operation: .channelWaitClosed,
                    fallbackCode: waitClosedResult
                )
            }
            throw SSHError.socketError("SCP wait close failed: \(waitClosedResult)")
        }

        let exitStatus = driver.channelExitStatus(channel)
        let freeResult = driver.freeChannel(channel)
        if freeResult != 0, freeResult != LIBSSH2_ERROR_EAGAIN {
            if let session = libssh2Session {
                logChannelFailure(session: session, operation: .channelFree, fallbackCode: freeResult)
            } else {
                logger.debug("libssh2 upload channel free returned \(freeResult) [message: no active session]")
            }
        }
        return exitStatus
    }

    private func drainChannelOutput(_ channel: OpaquePointer) async throws {
        var buffer = [CChar](repeating: 0, count: 4096)

        while true {
            try Task.checkCancellation()
            let stdoutRead = driver.readChannel(channel, stream: 0, into: &buffer)
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
            let stderrRead = driver.readChannel(channel, stream: 1, into: &buffer)
            if stderrRead > 0 {
                continue
            }
            if stderrRead == Int(LIBSSH2_ERROR_EAGAIN) || stderrRead == 0 {
                break
            }
            throw SSHError.socketError("Exec upload stderr drain failed: \(stderrRead)")
        }
    }


}
