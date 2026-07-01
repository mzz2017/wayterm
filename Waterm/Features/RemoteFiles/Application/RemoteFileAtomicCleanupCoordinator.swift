import Foundation

nonisolated struct RemoteFileAtomicCleanupCoordinator: Sendable {
    func removeTemporaryFile(
        _ temporaryRemotePath: String,
        using service: any RemoteFileService
    ) async {
        let cleanupTask = Task.detached {
            try? await service.deleteFile(at: temporaryRemotePath)
        }
        await cleanupTask.value
    }

    func removeTemporaryDirectory(
        _ temporaryRemotePath: String,
        using service: any RemoteFileService
    ) async {
        let cleanupTask = Task.detached {
            await Self.deleteRemoteDirectoryRecursivelyIgnoringCancellation(
                at: temporaryRemotePath,
                using: service
            )
        }
        await cleanupTask.value
    }

    private static func deleteRemoteDirectoryRecursivelyIgnoringCancellation(
        at remotePath: String,
        using service: any RemoteFileService
    ) async {
        do {
            let normalizedPath = RemoteFilePath.normalize(remotePath)
            let entries = try await service.listDirectory(at: normalizedPath, maxEntries: nil)

            for entry in entries {
                switch entry.type {
                case .directory:
                    await deleteRemoteDirectoryRecursivelyIgnoringCancellation(at: entry.path, using: service)
                case .file, .symlink, .other:
                    try? await service.deleteFile(at: entry.path)
                }
            }

            try? await service.deleteDirectory(at: normalizedPath)
        } catch {
            try? await service.deleteDirectory(at: RemoteFilePath.normalize(remotePath))
        }
    }
}
