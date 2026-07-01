import Foundation

nonisolated struct RemoteFileCopyEntriesCoordinator {
    typealias TransferProgressTracker = RemoteFileBrowserStore.TransferProgressTracker
    typealias CopyOperation = @Sendable (
        RemoteFileEntry,
        String,
        TransferProgressTracker?
    ) async throws -> Void

    let conflictResolver: RemoteFileConflictResolver

    init(conflictResolver: RemoteFileConflictResolver = RemoteFileConflictResolver()) {
        self.conflictResolver = conflictResolver
    }

    func copyEntries(
        _ entries: [RemoteFileEntry],
        to destinationDirectoryPath: String,
        using destinationService: any RemoteFileService,
        progressTracker: TransferProgressTracker?,
        copyEntry: CopyOperation
    ) async throws {
        guard !entries.isEmpty else { return }

        let destinationDirectory = RemoteFilePath.normalize(destinationDirectoryPath)
        var reservedNames: Set<String> = []

        for entry in entries {
            try Task.checkCancellation()
            while true {
                let resolution = try await conflictResolver.resolveName(
                    for: entry.name,
                    in: destinationDirectory,
                    policy: .keepBoth,
                    using: destinationService,
                    reservedNames: &reservedNames
                )

                do {
                    try await copyEntry(entry, resolution.resolvedName, progressTracker)
                    break
                } catch RemoteFilePublishError.destinationExists(_) {
                    continue
                }
            }
        }
    }
}
