import Foundation

nonisolated struct RemoteFileAtomicDirectoryCopyCoordinator: Sendable {
    typealias TransferProgressTracker = RemoteFileBrowserStore.TransferProgressTracker
    typealias ChildCopyOperation = @MainActor (
        _ entry: RemoteFileEntry,
        _ temporaryRemoteDirectoryPath: String
    ) async throws -> Void

    let atomicUploader: RemoteFileAtomicUploader

    init(atomicUploader: RemoteFileAtomicUploader = RemoteFileAtomicUploader()) {
        self.atomicUploader = atomicUploader
    }

    func copyDirectory(
        _ entry: RemoteFileEntry,
        effectiveEntry: RemoteFileEntry,
        to remoteDirectoryPath: String,
        remoteName: String? = nil,
        sourceService: any RemoteFileService,
        destinationService: any RemoteFileService,
        progressTracker: TransferProgressTracker?,
        copyChild: ChildCopyOperation
    ) async throws {
        let targetName = remoteName ?? entry.name
        let remotePath = RemoteFilePath.appending(targetName, to: remoteDirectoryPath)
        let temporaryRemotePath = makeAtomicRemoteDirectoryCopyPath(for: remotePath)

        do {
            try await destinationService.createDirectory(
                at: temporaryRemotePath,
                permissions: modeBits(from: effectiveEntry.permissions, fallback: 0o755)
            )
            let children = try await sourceService.listDirectory(at: entry.path, maxEntries: nil)
            for child in children {
                try Task.checkCancellation()
                try await copyChild(child, temporaryRemotePath)
            }
            try Task.checkCancellation()
            try await atomicUploader.publishAtomicRemoteItem(
                at: temporaryRemotePath,
                to: remotePath,
                publishMode: .failIfDestinationExists,
                using: destinationService
            )
            await progressTracker?.advance(currentItemName: targetName)
        } catch {
            await removeAtomicRemoteDirectory(temporaryRemotePath, using: destinationService)
            throw error
        }
    }

    private func modeBits(from permissions: UInt32?, fallback: Int32) -> Int32 {
        guard let permissions else { return fallback }
        return Int32(permissions & 0o7777)
    }

    private func removeAtomicRemoteDirectory(
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

    private nonisolated static func deleteRemoteDirectoryRecursivelyIgnoringCancellation(
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

    private func makeAtomicRemoteDirectoryCopyPath(for remotePath: String) -> String {
        let normalizedPath = RemoteFilePath.normalize(remotePath)
        let parentPath = RemoteFilePath.parent(of: normalizedPath)
        let targetName = normalizedPath.split(separator: "/").last.map(String.init) ?? "copy"
        return RemoteFilePath.appending(
            ".\(targetName).vvterm-copy-\(UUID().uuidString).tmp",
            to: parentPath
        )
    }
}
