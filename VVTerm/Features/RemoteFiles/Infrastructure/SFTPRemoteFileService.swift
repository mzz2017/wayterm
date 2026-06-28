import Foundation

struct SFTPRemoteFileService: RemoteFileService {
    let client: any SFTPRemoteFileClient

    func listDirectory(at path: String, maxEntries: Int? = nil) async throws -> [RemoteFileEntry] {
        try await mapSSHFileTransferError {
            try await client.listDirectory(at: path, maxEntries: maxEntries).map(RemoteFileEntry.init(sshEntry:))
        }
    }

    func stat(at path: String) async throws -> RemoteFileEntry {
        try await mapSSHFileTransferError {
            let entry = try await client.stat(at: path)
            return RemoteFileEntry(sshEntry: entry)
        }
    }

    func lstat(at path: String) async throws -> RemoteFileEntry {
        try await mapSSHFileTransferError {
            let entry = try await client.lstat(at: path)
            return RemoteFileEntry(sshEntry: entry)
        }
    }

    func readFile(at path: String, maxBytes: Int) async throws -> Data {
        try await mapSSHFileTransferError {
            try await client.readFile(at: path, maxBytes: maxBytes)
        }
    }

    func downloadFile(at path: String, to localURL: URL) async throws {
        try await mapSSHFileTransferError {
            try await client.downloadFile(at: path, to: localURL)
        }
    }

    func upload(
        _ data: Data,
        to remotePath: String,
        permissions: Int32,
        strategy: SSHUploadStrategy = .automatic
    ) async throws {
        try await mapSSHFileTransferError {
            try await client.upload(
                data,
                to: remotePath,
                permissions: permissions,
                strategy: strategy
            )
        }
    }

    func createDirectory(at path: String, permissions: Int32) async throws {
        try await mapSSHFileTransferError {
            try await client.createDirectory(at: path, permissions: permissions)
        }
    }

    func renameItem(at sourcePath: String, to destinationPath: String) async throws {
        try await mapSSHFileTransferError {
            try await client.renameItem(at: sourcePath, to: destinationPath)
        }
    }

    func deleteFile(at path: String) async throws {
        try await mapSSHFileTransferError {
            try await client.deleteFile(at: path)
        }
    }

    func deleteDirectory(at path: String) async throws {
        try await mapSSHFileTransferError {
            try await client.deleteDirectory(at: path)
        }
    }

    func setPermissions(at path: String, permissions: UInt32) async throws {
        try await mapSSHFileTransferError {
            try await client.setPermissions(at: path, permissions: permissions)
        }
    }

    func resolveHomeDirectory() async throws -> String {
        try await mapSSHFileTransferError {
            try await client.resolveHomeDirectory()
        }
    }

    func fileSystemStatus(at path: String) async throws -> RemoteFileFilesystemStatus {
        try await mapSSHFileTransferError {
            RemoteFileFilesystemStatus(sshStatus: try await client.fileSystemStatus(at: path))
        }
    }

    private func mapSSHFileTransferError<T>(
        _ operation: () async throws -> T
    ) async throws -> T {
        do {
            return try await operation()
        } catch let error as SSHFileTransferError {
            throw RemoteFileBrowserError(sshError: error)
        } catch {
            throw error
        }
    }
}
