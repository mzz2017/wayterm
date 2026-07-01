import Foundation

nonisolated struct RemoteFileAtomicDirectoryCopyCoordinator: Sendable {
    typealias TransferProgressTracker = RemoteFileBrowserStore.TransferProgressTracker
    typealias ChildCopyOperation = @Sendable (
        _ entry: RemoteFileEntry,
        _ temporaryRemoteDirectoryPath: String
    ) async throws -> Void

    let atomicUploader: RemoteFileAtomicUploader
    let cleanupCoordinator: RemoteFileAtomicCleanupCoordinator

    init(
        atomicUploader: RemoteFileAtomicUploader = RemoteFileAtomicUploader(),
        cleanupCoordinator: RemoteFileAtomicCleanupCoordinator = RemoteFileAtomicCleanupCoordinator()
    ) {
        self.atomicUploader = atomicUploader
        self.cleanupCoordinator = cleanupCoordinator
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
            let children = try await sourceService.listDirectory(at: effectiveEntry.path, maxEntries: nil)
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
            await cleanupCoordinator.removeTemporaryDirectory(temporaryRemotePath, using: destinationService)
            throw error
        }
    }

    private func modeBits(from permissions: UInt32?, fallback: Int32) -> Int32 {
        guard let permissions else { return fallback }
        return Int32(permissions & 0o7777)
    }

    private func makeAtomicRemoteDirectoryCopyPath(for remotePath: String) -> String {
        let normalizedPath = RemoteFilePath.normalize(remotePath)
        let parentPath = RemoteFilePath.parent(of: normalizedPath)
        let targetName = normalizedPath.split(separator: "/").last.map(String.init) ?? "copy"
        return RemoteFilePath.appending(
            ".\(targetName).waterm-copy-\(UUID().uuidString).tmp",
            to: parentPath
        )
    }
}
