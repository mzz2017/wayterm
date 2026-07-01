//
//  SSHSession+RemoteFiles.swift
//  VVTerm
//
//  Remote file and SFTP operations for SSHSession.
//

import Foundation
import os

extension SSHSession {
    // MARK: - Remote Files

    func listDirectory(at path: String, maxEntries: Int? = nil) async throws -> [SSHFileTransferEntry] {
        let sftp = try await ensureSFTPSession()
        let normalizedPath = Self.normalizeRemotePath(path)
        let handle = try await openDirectoryHandle(at: normalizedPath, sftp: sftp)
        defer { closeSFTPHandle(handle, after: "list directory") }

        let limit = maxEntries ?? .max
        var entries: [SSHFileTransferEntry] = []
        var nameBuffer = [CChar](repeating: 0, count: 4096)

        while entries.count < limit {
            try Task.checkCancellation()
            var attributes = LIBSSH2_SFTP_ATTRIBUTES()

            let bytesRead = driver.readSFTPDirectory(
                handle: handle,
                into: &nameBuffer,
                attributes: &attributes
            )

            if bytesRead > 0 {
                let name = Self.string(from: nameBuffer, length: bytesRead)
                guard name != "." && name != ".." else { continue }

                let entryPath = Self.appendRemotePathComponent(name, to: normalizedPath)
                let baseEntry = SSHFileTransferEntry.from(
                    name: name,
                    path: entryPath,
                    attributes: attributes
                )
                let symlinkTarget = baseEntry.type == .symlink ? (try? await readlink(at: entryPath)) : nil
                entries.append(
                    SSHFileTransferEntry.from(
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

            throw sftpFailure(
                from: sftp,
                rawOperation: .sftpReadDirectory,
                operation: "read directory",
                path: normalizedPath
            )
        }

        return entries
    }

    func stat(at path: String) async throws -> SSHFileTransferEntry {
        try await stat(at: path, statType: Int32(LIBSSH2_SFTP_STAT))
    }

    func lstat(at path: String) async throws -> SSHFileTransferEntry {
        try await stat(at: path, statType: Int32(LIBSSH2_SFTP_LSTAT))
    }

    func readlink(at path: String) async throws -> String {
        let sftp = try await ensureSFTPSession()
        return try await readSymlinkTarget(at: path, linkType: Int32(LIBSSH2_SFTP_READLINK), sftp: sftp)
    }

    func readFile(at path: String, maxBytes: Int, offset: UInt64 = 0) async throws -> Data {
        guard maxBytes > 0 else { return Data() }

        let sftp = try await ensureSFTPSession()
        let normalizedPath = Self.normalizeRemotePath(path)
        let handle = try await openFileHandle(
            at: normalizedPath,
            sftp: sftp,
            flags: UInt32(LIBSSH2_FXF_READ),
            mode: 0
        )
        defer { closeSFTPHandle(handle, after: "read file") }

        if offset > 0 {
            driver.seekSFTPFile(handle: handle, offset: offset)
        }

        var data = Data()
        data.reserveCapacity(min(maxBytes, 32 * 1024))

        while data.count < maxBytes {
            try Task.checkCancellation()
            let remaining = maxBytes - data.count
            let chunkSize = min(32 * 1024, remaining)
            var buffer = [CChar](repeating: 0, count: chunkSize)

            let bytesRead = driver.readSFTPFile(handle: handle, into: &buffer)

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

            throw sftpFailure(
                from: sftp,
                rawOperation: .sftpRead,
                operation: "read file",
                path: normalizedPath
            )
        }

        return data
    }

    func downloadFile(at path: String, to localURL: URL) async throws {
        let sftp = try await ensureSFTPSession()
        let normalizedPath = Self.normalizeRemotePath(path)
        let handle = try await openFileHandle(
            at: normalizedPath,
            sftp: sftp,
            flags: UInt32(LIBSSH2_FXF_READ),
            mode: 0
        )
        defer { closeSFTPHandle(handle, after: "download file") }

        let fileManager = FileManager.default
        let destinationDirectory = localURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        let temporaryURL = destinationDirectory.appendingPathComponent(
            ".\(localURL.lastPathComponent).vvterm-download-\(UUID().uuidString).tmp"
        )
        try? fileManager.removeItem(at: temporaryURL)
        guard fileManager.createFile(atPath: temporaryURL.path, contents: nil) else {
            throw SSHFileTransferError.failed(operation: "create local download file", path: localURL.path)
        }

        let localFileHandle = try FileHandle(forWritingTo: temporaryURL)
        do {
            while true {
                try Task.checkCancellation()
                var buffer = [CChar](repeating: 0, count: 64 * 1024)

                let bytesRead = driver.readSFTPFile(handle: handle, into: &buffer)

                if bytesRead > 0 {
                    try localFileHandle.write(contentsOf: Data(buffer.prefix(bytesRead).map { UInt8(bitPattern: $0) }))
                    continue
                }

                if bytesRead == 0 {
                    break
                }

                if bytesRead == Int(LIBSSH2_ERROR_EAGAIN) {
                    await waitForSocket()
                    continue
                }

                throw sftpFailure(
                    from: sftp,
                    rawOperation: .sftpRead,
                    operation: "download file",
                    path: normalizedPath
                )
            }

            try localFileHandle.close()
            if fileManager.fileExists(atPath: localURL.path) {
                _ = try fileManager.replaceItemAt(localURL, withItemAt: temporaryURL)
            } else {
                try fileManager.moveItem(at: temporaryURL, to: localURL)
            }
        } catch {
            try? localFileHandle.close()
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
    }

    func writeFile(_ data: Data, to path: String, permissions: Int32 = 0o644) async throws {
        let sftp = try await ensureSFTPSession()
        let normalizedPath = Self.normalizeRemotePath(path)
        let handle = try await openFileHandle(
            at: normalizedPath,
            sftp: sftp,
            flags: UInt32(LIBSSH2_FXF_WRITE | LIBSSH2_FXF_TRUNC | LIBSSH2_FXF_CREAT),
            mode: permissions,
            operation: "write file"
        )
        defer { closeSFTPHandle(handle, after: "write file") }

        var totalBytesWritten = 0
        while totalBytesWritten < data.count {
            try Task.checkCancellation()

            let bytesWritten = driver.writeSFTPFile(
                handle: handle,
                data: data,
                offset: totalBytesWritten,
                maxLength: min(64 * 1024, data.count - totalBytesWritten)
            )

            if bytesWritten > 0 {
                totalBytesWritten += bytesWritten
                continue
            }

            if bytesWritten == Int(LIBSSH2_ERROR_EAGAIN) {
                await waitForSocket()
                continue
            }

            throw sftpFailure(
                from: sftp,
                rawOperation: .sftpWrite,
                operation: "write file",
                path: normalizedPath
            )
        }
    }

    private func closeSFTPHandle(_ handle: OpaquePointer, after operation: String) {
        let closeResult = driver.closeSFTPHandle(handle)
        guard closeResult != 0 else { return }
        guard let session = libssh2Session else {
            logger.debug(
                "libssh2 sftp handle close after \(operation, privacy: .public) returned \(closeResult) [message: no active session]"
            )
            return
        }

        let rawError = driver.lastError(
            session: session,
            operation: .sftpCloseHandle,
            fallbackCode: closeResult
        )
        logger.debug(
            "libssh2 sftp handle close after \(operation, privacy: .public) returned \(rawError.code) [message: \(rawError.message ?? "none", privacy: .public)]"
        )
    }

    func resolveHomeDirectory() async throws -> String {
        let sftp = try await ensureSFTPSession()
        let path = try await readSymlinkTarget(at: ".", linkType: Int32(LIBSSH2_SFTP_REALPATH), sftp: sftp)
        return path.isEmpty ? "/" : path
    }

    func fileSystemStatus(at path: String) async throws -> SSHFileTransferFilesystemStatus {
        let sftp = try await ensureSFTPSession()
        let normalizedPath = Self.normalizeRemotePath(path)
        var status = LIBSSH2_SFTP_STATVFS()

        while true {
            try Task.checkCancellation()

            let result = driver.statSFTPFileSystem(sftp: sftp, path: normalizedPath, status: &status)

            if result == 0 {
                let fragmentSize = UInt64(status.f_frsize)
                let blockSize = fragmentSize > 0 ? fragmentSize : UInt64(status.f_bsize)
                return SSHFileTransferFilesystemStatus(
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

            throw sftpFailure(
                from: sftp,
                rawOperation: .sftpStatVFS,
                operation: "read filesystem status",
                path: normalizedPath
            )
        }
    }

    func createDirectory(at path: String, permissions: Int32 = 0o755) async throws {
        let sftp = try await ensureSFTPSession()
        let normalizedPath = Self.normalizeRemotePath(path)
        try await performSFTPMutation(
            at: normalizedPath,
            sftp: sftp,
            operation: "create directory",
            rawOperation: .sftpMakeDirectory
        ) { sftpHandle, mutationPath in
            driver.makeSFTPDirectory(sftp: sftpHandle, path: mutationPath, permissions: permissions)
        }
    }

    func setPermissions(at path: String, permissions: UInt32) async throws {
        let sftp = try await ensureSFTPSession()
        let normalizedPath = Self.normalizeRemotePath(path)
        var attributes = LIBSSH2_SFTP_ATTRIBUTES()
        attributes.flags = UInt(LIBSSH2_SFTP_ATTR_PERMISSIONS)
        attributes.permissions = UInt(permissions)

        while true {
            try Task.checkCancellation()

            let result = driver.statSFTPPath(
                sftp: sftp,
                path: normalizedPath,
                statType: Int32(LIBSSH2_SFTP_SETSTAT),
                attributes: &attributes
            )

            if result == 0 {
                return
            }

            if result == Int32(LIBSSH2_ERROR_EAGAIN) {
                await waitForSocket()
                continue
            }

            throw sftpFailure(
                from: sftp,
                rawOperation: .sftpSetStat,
                operation: "set permissions",
                path: normalizedPath
            )
        }
    }

    func renameItem(at sourcePath: String, to destinationPath: String) async throws {
        let sftp = try await ensureSFTPSession()
        let normalizedSource = Self.normalizeRemotePath(sourcePath)
        let normalizedDestination = Self.normalizeRemotePath(destinationPath)
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
                    operation: "rename",
                    rawOperation: .sftpRename
                ) { sftpHandle, sourcePath in
                    driver.renameSFTPPath(
                        sftp: sftpHandle,
                        sourcePath: sourcePath,
                        destinationPath: normalizedDestination,
                        flags: flags
                    )
                }
                return
            } catch {
                lastError = error
            }
        }

        throw lastError ?? SSHFileTransferError.failed(operation: "rename", path: normalizedSource)
    }

    func renameItemIfDestinationMissing(at sourcePath: String, to destinationPath: String) async throws {
        let sftp = try await ensureSFTPSession()
        let normalizedSource = Self.normalizeRemotePath(sourcePath)
        let normalizedDestination = Self.normalizeRemotePath(destinationPath)
        let renameFlagCandidates: [Int] = [
            Int(LIBSSH2_SFTP_RENAME_ATOMIC) |
                Int(LIBSSH2_SFTP_RENAME_NATIVE),
            Int(LIBSSH2_SFTP_RENAME_NATIVE),
            0
        ]

        var lastError: Error?

        for flags in renameFlagCandidates {
            do {
                try await performSFTPMutation(
                    at: normalizedSource,
                    sftp: sftp,
                    operation: "rename",
                    rawOperation: .sftpRename
                ) { sftpHandle, sourcePath in
                    driver.renameSFTPPath(
                        sftp: sftpHandle,
                        sourcePath: sourcePath,
                        destinationPath: normalizedDestination,
                        flags: flags
                    )
                }
                return
            } catch {
                lastError = error
            }
        }

        throw lastError ?? SSHFileTransferError.failed(operation: "rename", path: normalizedSource)
    }

    func deleteFile(at path: String) async throws {
        let sftp = try await ensureSFTPSession()
        let normalizedPath = Self.normalizeRemotePath(path)
        try await performSFTPMutation(
            at: normalizedPath,
            sftp: sftp,
            operation: "delete file",
            rawOperation: .sftpUnlink
        ) { sftpHandle, mutationPath in
            driver.unlinkSFTPFile(sftp: sftpHandle, path: mutationPath)
        }
    }

    func deleteDirectory(at path: String) async throws {
        let sftp = try await ensureSFTPSession()
        let normalizedPath = Self.normalizeRemotePath(path)
        try await performSFTPMutation(
            at: normalizedPath,
            sftp: sftp,
            operation: "delete directory",
            rawOperation: .sftpRemoveDirectory
        ) { sftpHandle, mutationPath in
            driver.removeSFTPDirectory(sftp: sftpHandle, path: mutationPath)
        }
    }


    private func ensureSFTPSession() async throws -> OpaquePointer {
        if let sftpSession {
            return sftpSession
        }

        guard let session = libssh2Session else {
            throw SSHFileTransferError.disconnected
        }

        while true {
            try Task.checkCancellation()

            if let sftpSession = driver.initSFTPSession(session: session) {
                self.sftpSession = sftpSession
                return sftpSession
            }

            let rawError = driver.lastError(session: session, operation: .sftpInit, fallbackCode: 0)
            if rawError.code == LIBSSH2_ERROR_EAGAIN {
                await waitForSocket()
                continue
            }

            throw SSHError.libssh2(rawError)
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
            throw SSHFileTransferError.disconnected
        }

        while true {
            try Task.checkCancellation()

            if let handle = driver.openSFTPHandle(
                sftp: sftp,
                path: path,
                flags: flags,
                mode: mode,
                openType: openType
            ) {
                return handle
            }

            let rawError = driver.lastError(session: session, operation: .sftpOpen, fallbackCode: 0)
            if rawError.code == LIBSSH2_ERROR_EAGAIN {
                await waitForSocket()
                continue
            }
            if let rawError = sftpTransportError(rawError) {
                throw SSHError.libssh2(rawError)
            }

            throw remoteFileError(from: sftp, operation: operation, path: path)
        }
    }

    private func performSFTPMutation(
        at path: String,
        sftp: OpaquePointer,
        operation: String,
        rawOperation: LibSSH2RawError.Operation,
        mutation: (OpaquePointer, String) -> Int
    ) async throws {
        guard libssh2Session != nil else {
            throw SSHFileTransferError.disconnected
        }

        while true {
            try Task.checkCancellation()

            let result = mutation(sftp, path)

            if result == 0 {
                return
            }

            if result == Int(LIBSSH2_ERROR_EAGAIN) {
                await waitForSocket()
                continue
            }

            throw sftpFailure(
                from: sftp,
                rawOperation: rawOperation,
                operation: operation,
                path: path
            )
        }
    }

    private func stat(at path: String, statType: Int32) async throws -> SSHFileTransferEntry {
        let sftp = try await ensureSFTPSession()
        let normalizedPath = Self.normalizeRemotePath(path)
        var attributes = LIBSSH2_SFTP_ATTRIBUTES()

        while true {
            try Task.checkCancellation()

            let result = driver.statSFTPPath(
                sftp: sftp,
                path: normalizedPath,
                statType: statType,
                attributes: &attributes
            )

            if result == 0 {
                let entryName = Self.fileName(for: normalizedPath)
                var symlinkTarget: String?
                let entry = SSHFileTransferEntry.from(name: entryName, path: normalizedPath, attributes: attributes)
                if statType == Int32(LIBSSH2_SFTP_LSTAT), entry.type == .symlink {
                    symlinkTarget = try? await readlink(at: normalizedPath)
                }
                return SSHFileTransferEntry.from(
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

            throw sftpFailure(
                from: sftp,
                rawOperation: .sftpStat,
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
            throw SSHFileTransferError.disconnected
        }

        let requestPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPath = requestPath.isEmpty ? "." : requestPath
        var buffer = [CChar](repeating: 0, count: 4096)

        while true {
            try Task.checkCancellation()

            let result = driver.readSFTPSymlink(
                sftp: sftp,
                path: normalizedPath,
                targetBuffer: &buffer,
                linkType: linkType
            )

            if result >= 0 {
                return Self.string(from: buffer, length: result)
            }

            let rawError = driver.lastError(session: session, operation: .sftpSymlink, fallbackCode: Int32(result))
            if rawError.code == LIBSSH2_ERROR_EAGAIN {
                await waitForSocket()
                continue
            }
            if let rawError = sftpTransportError(rawError) {
                throw SSHError.libssh2(rawError)
            }

            throw remoteFileError(
                from: sftp,
                operation: linkType == Int32(LIBSSH2_SFTP_REALPATH) ? "resolve path" : "read link",
                path: normalizedPath
            )
        }
    }

    func closeSFTPSession() {
        guard let sftpSession else { return }
        let shutdownResult = driver.shutdownSFTPSession(sftpSession)
        if shutdownResult != 0, shutdownResult != LIBSSH2_ERROR_EAGAIN {
            if let session = libssh2Session {
                let rawError = driver.lastError(
                    session: session,
                    operation: .sftpShutdown,
                    fallbackCode: shutdownResult
                )
                logger.debug(
                    "libssh2 sftp shutdown returned \(rawError.code) [message: \(rawError.message ?? "none", privacy: .public)]"
                )
            } else {
                logger.debug("libssh2 sftp shutdown returned \(shutdownResult) [message: no active session]")
            }
        }
        self.sftpSession = nil
    }

    private static func fileName(for path: String) -> String {
        let normalized = normalizeRemotePath(path)
        guard normalized != "/" else { return "/" }
        return normalized.split(separator: "/").last.map(String.init) ?? normalized
    }

    private static func normalizeRemotePath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "/" }

        let hasLeadingSlash = trimmed.hasPrefix("/")
        let components = trimmed
            .split(separator: "/", omittingEmptySubsequences: true)
            .reduce(into: [String]()) { result, component in
                switch component {
                case ".":
                    break
                case "..":
                    if !result.isEmpty {
                        result.removeLast()
                    }
                default:
                    result.append(String(component))
                }
            }

        let joined = components.joined(separator: "/")
        if hasLeadingSlash {
            return joined.isEmpty ? "/" : "/\(joined)"
        }
        return joined.isEmpty ? "." : joined
    }

    private static func appendRemotePathComponent(_ component: String, to basePath: String) -> String {
        let normalizedBase = normalizeRemotePath(basePath)
        if normalizedBase == "/" {
            return "/\(component)"
        }
        if normalizedBase == "." {
            return component
        }
        return "\(normalizedBase)/\(component)"
    }

    private static func string(from buffer: [CChar], length: Int) -> String {
        let bytes = buffer.prefix(length).map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    private func remoteFileError(
        from sftp: OpaquePointer?,
        operation: String,
        path: String?
    ) -> SSHFileTransferError {
        let code = sftp.map { driver.lastSFTPError($0) } ?? 0
        return SSHRemoteFileErrorMapper.remoteFileError(
            lastError: code,
            operation: operation,
            path: path
        )
    }

    private func sftpFailure(
        from sftp: OpaquePointer?,
        rawOperation: LibSSH2RawError.Operation,
        operation: String,
        path: String?
    ) -> Error {
        if let rawError = sftpTransportError(operation: rawOperation) {
            return SSHError.libssh2(rawError)
        }

        return remoteFileError(from: sftp, operation: operation, path: path)
    }

    private func sftpTransportError(operation: LibSSH2RawError.Operation) -> LibSSH2RawError? {
        guard let session = libssh2Session else { return nil }
        let rawError = driver.lastError(session: session, operation: operation, fallbackCode: 0)
        return sftpTransportError(rawError)
    }

    private func sftpTransportError(_ rawError: LibSSH2RawError) -> LibSSH2RawError? {
        switch rawError.code {
        case 0, LIBSSH2_ERROR_EAGAIN, LIBSSH2_ERROR_SFTP_PROTOCOL:
            return nil
        default:
            return rawError
        }
    }
}
