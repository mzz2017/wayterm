import Foundation

nonisolated struct RemoteFilePermissionEditContext: Equatable, Sendable {
    let draft: RemoteFilePermissionDraft
    let originalAccessBits: UInt32
    let preservedBits: UInt32
    let fileTypeBits: UInt32
}

nonisolated enum RemoteFilePermissionEditPolicy {
    static func canEditPermissions(for entry: RemoteFileEntry) -> Bool {
        guard entry.permissions != nil else { return false }
        return entry.type != .symlink
    }

    static func context(for entry: RemoteFileEntry) -> RemoteFilePermissionEditContext? {
        guard canEditPermissions(for: entry), let permissions = entry.permissions else { return nil }

        return RemoteFilePermissionEditContext(
            draft: RemoteFilePermissionDraft(accessBits: permissions),
            originalAccessBits: permissions & 0o777,
            preservedBits: entry.specialPermissionBits,
            fileTypeBits: permissions & UInt32(LIBSSH2_SFTP_S_IFMT)
        )
    }

    static func requestedPermissions(
        draft: RemoteFilePermissionDraft,
        context: RemoteFilePermissionEditContext
    ) -> UInt32 {
        context.fileTypeBits | context.preservedBits | draft.accessBits
    }
}
