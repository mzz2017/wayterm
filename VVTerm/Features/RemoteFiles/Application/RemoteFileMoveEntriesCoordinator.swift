import Foundation

nonisolated struct RemoteFileMoveEntriesCoordinator {
    struct Failure: Error {
        let didMutate: Bool
        let underlyingError: any Error
    }

    func moveEntries(
        _ moves: [RemoteFileDropPolicy.MovePlan],
        using service: any RemoteFileService,
        onProgress: RemoteFileBrowserStore.TransferProgressCallback? = nil
    ) async throws {
        guard !moves.isEmpty else { return }

        let totalUnitCount = max(1, moves.count)
        var didMutate = false

        do {
            for (index, move) in moves.enumerated() {
                try Task.checkCancellation()
                try await service.renameItem(at: move.sourcePath, to: move.destinationPath)
                didMutate = true
                await onProgress?(
                    RemoteFileBrowserStore.TransferProgress(
                        completedUnitCount: index + 1,
                        totalUnitCount: totalUnitCount,
                        currentItemName: move.entry.name
                    )
                )
            }
        } catch {
            if didMutate {
                throw Failure(didMutate: true, underlyingError: error)
            }
            throw error
        }
    }
}
