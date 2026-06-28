import Foundation

extension RemoteFileEntry {
    nonisolated init(sshEntry: SSHFileTransferEntry) {
        self.init(
            name: sshEntry.name,
            path: sshEntry.path,
            type: RemoteFileType(sshType: sshEntry.type),
            size: sshEntry.size,
            modifiedAt: sshEntry.modifiedAt,
            permissions: sshEntry.permissions,
            symlinkTarget: sshEntry.symlinkTarget
        )
    }
}

extension SSHFileTransferEntry {
    nonisolated init(remoteFileEntry: RemoteFileEntry) {
        self.init(
            name: remoteFileEntry.name,
            path: remoteFileEntry.path,
            type: SSHFileTransferEntryType(remoteFileType: remoteFileEntry.type),
            size: remoteFileEntry.size,
            modifiedAt: remoteFileEntry.modifiedAt,
            permissions: remoteFileEntry.permissions,
            symlinkTarget: remoteFileEntry.symlinkTarget
        )
    }
}

extension RemoteFileType {
    nonisolated init(sshType: SSHFileTransferEntryType) {
        switch sshType {
        case .file:
            self = .file
        case .directory:
            self = .directory
        case .symlink:
            self = .symlink
        case .other:
            self = .other
        }
    }
}

extension SSHFileTransferEntryType {
    nonisolated init(remoteFileType: RemoteFileType) {
        switch remoteFileType {
        case .file:
            self = .file
        case .directory:
            self = .directory
        case .symlink:
            self = .symlink
        case .other:
            self = .other
        }
    }
}

extension RemoteFileFilesystemStatus {
    nonisolated init(sshStatus: SSHFileTransferFilesystemStatus) {
        self.init(
            blockSize: sshStatus.blockSize,
            totalBlocks: sshStatus.totalBlocks,
            freeBlocks: sshStatus.freeBlocks,
            availableBlocks: sshStatus.availableBlocks
        )
    }
}

extension SSHFileTransferFilesystemStatus {
    nonisolated init(remoteFileStatus: RemoteFileFilesystemStatus) {
        self.init(
            blockSize: remoteFileStatus.blockSize,
            totalBlocks: remoteFileStatus.totalBlocks,
            freeBlocks: remoteFileStatus.freeBlocks,
            availableBlocks: remoteFileStatus.availableBlocks
        )
    }
}

extension RemoteFileBrowserError {
    nonisolated init(sshError: SSHFileTransferError) {
        switch sshError {
        case .permissionDenied:
            self = .permissionDenied
        case .pathNotFound:
            self = .pathNotFound
        case .disconnected:
            self = .disconnected
        case .notDirectory:
            self = .failed(String(localized: "The remote path is not a directory."))
        case .linkLoop:
            self = .failed(String(localized: "The remote path contains a symbolic link loop."))
        case .failed:
            self = .failed(sshError.localizedDescription)
        }
    }
}
