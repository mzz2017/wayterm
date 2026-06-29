import Foundation

nonisolated enum SSHFileTransferEntryType: String, Sendable {
    case file
    case directory
    case symlink
    case other
}

nonisolated struct SSHFileTransferEntry: Hashable, Sendable {
    let name: String
    let path: String
    let type: SSHFileTransferEntryType
    let size: UInt64?
    let modifiedAt: Date?
    let permissions: UInt32?
    let symlinkTarget: String?

    static func from(
        name: String,
        path: String,
        attributes: LIBSSH2_SFTP_ATTRIBUTES,
        symlinkTarget: String? = nil
    ) -> SSHFileTransferEntry {
        let flags = UInt32(attributes.flags)
        let permissionBits = UInt32(attributes.permissions)
        let type = fileType(from: permissionBits, flags: flags)
        let size = flags & UInt32(LIBSSH2_SFTP_ATTR_SIZE) != 0
            ? UInt64(attributes.filesize)
            : nil
        let modifiedAt = flags & UInt32(LIBSSH2_SFTP_ATTR_ACMODTIME) != 0
            ? Date(timeIntervalSince1970: TimeInterval(attributes.mtime))
            : nil
        let permissions = flags & UInt32(LIBSSH2_SFTP_ATTR_PERMISSIONS) != 0
            ? permissionBits
            : nil

        return SSHFileTransferEntry(
            name: name,
            path: path,
            type: type,
            size: size,
            modifiedAt: modifiedAt,
            permissions: permissions,
            symlinkTarget: symlinkTarget
        )
    }

    private static func fileType(from permissions: UInt32, flags: UInt32) -> SSHFileTransferEntryType {
        guard flags & UInt32(LIBSSH2_SFTP_ATTR_PERMISSIONS) != 0 else {
            return .other
        }

        let typeMask = permissions & UInt32(LIBSSH2_SFTP_S_IFMT)
        switch typeMask {
        case UInt32(LIBSSH2_SFTP_S_IFDIR):
            return .directory
        case UInt32(LIBSSH2_SFTP_S_IFLNK):
            return .symlink
        case UInt32(LIBSSH2_SFTP_S_IFREG):
            return .file
        default:
            return .other
        }
    }
}

nonisolated struct SSHFileTransferFilesystemStatus: Hashable, Sendable {
    let blockSize: UInt64
    let totalBlocks: UInt64
    let freeBlocks: UInt64
    let availableBlocks: UInt64
}

nonisolated enum SSHFileTransferError: LocalizedError, Equatable, Sendable {
    case permissionDenied
    case pathNotFound
    case disconnected
    case notDirectory
    case linkLoop
    case failed(operation: String, path: String?, sftpStatusCode: UInt? = nil)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return String(localized: "Permission denied.")
        case .pathNotFound:
            return String(localized: "The remote path could not be found.")
        case .disconnected:
            return String(localized: "The remote connection was interrupted.")
        case .notDirectory:
            return String(localized: "The remote path is not a directory.")
        case .linkLoop:
            return String(localized: "The remote path contains a symbolic link loop.")
        case .failed(let operation, let path, let sftpStatusCode):
            let location = path.map { " (\($0))" } ?? ""
            let status = sftpStatusCode.map { " [SFTP status \($0)]" } ?? ""
            return String(localized: "Failed to \(operation)\(location)\(status).")
        }
    }
}
