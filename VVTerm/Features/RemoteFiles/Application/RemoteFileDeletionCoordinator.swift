import Foundation

nonisolated struct RemoteFileDeletionCoordinator: Sendable {
    func deleteEntry(
        _ entry: RemoteFileEntry,
        using service: any RemoteFileService
    ) async throws {
        switch entry.type {
        case .directory:
            try await deleteDirectoryRecursively(at: entry.path, using: service)
        case .file, .symlink, .other:
            try await service.deleteFile(at: entry.path)
        }
    }

    func deleteItem(
        at remotePath: String,
        type: RemoteFileType?,
        using service: any RemoteFileService
    ) async throws {
        switch type {
        case .directory:
            try await deleteDirectoryRecursively(at: remotePath, using: service)
        case .file, .symlink, .other, nil:
            try await service.deleteFile(at: remotePath)
        }
    }

    func deleteDirectoryRecursively(
        at remotePath: String,
        using service: any RemoteFileService
    ) async throws {
        let normalizedPath = RemoteFilePath.normalize(remotePath)
        let entries = try await service.listDirectory(at: normalizedPath, maxEntries: nil)

        for entry in entries {
            try Task.checkCancellation()
            try await deleteEntry(entry, using: service)
        }

        try Task.checkCancellation()
        try await service.deleteDirectory(at: normalizedPath)
    }
}
