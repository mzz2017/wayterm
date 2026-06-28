import Foundation

protocol SFTPRemoteFileClient: RemoteConnectionLeaseClient {
    func connectForRemoteFileLease(to server: Server, credentials: ServerCredentials) async throws
    func listDirectory(at path: String, maxEntries: Int?) async throws -> [SSHFileTransferEntry]
    func stat(at path: String) async throws -> SSHFileTransferEntry
    func lstat(at path: String) async throws -> SSHFileTransferEntry
    func readFile(at path: String, maxBytes: Int) async throws -> Data
    func downloadFile(at path: String, to localURL: URL) async throws
    func createDirectory(at path: String, permissions: Int32) async throws
    func renameItem(at sourcePath: String, to destinationPath: String) async throws
    func deleteFile(at path: String) async throws
    func deleteDirectory(at path: String) async throws
    func setPermissions(at path: String, permissions: UInt32) async throws
    func resolveHomeDirectory() async throws -> String
    func fileSystemStatus(at path: String) async throws -> SSHFileTransferFilesystemStatus
}

extension SSHClient: SFTPRemoteFileClient {
    func connectForRemoteFileLease(to server: Server, credentials: ServerCredentials) async throws {
        _ = try await connect(to: server, credentials: credentials)
    }

    func readFile(at path: String, maxBytes: Int) async throws -> Data {
        try await readFile(at: path, maxBytes: maxBytes, offset: 0)
    }
}
