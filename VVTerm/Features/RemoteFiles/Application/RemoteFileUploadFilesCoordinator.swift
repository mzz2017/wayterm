import Foundation

nonisolated struct RemoteFileUploadFilesCoordinator {
    typealias TransferProgressTracker = RemoteFileBrowserStore.TransferProgressTracker
    typealias CountTransferUnits = @Sendable ([URL]) async throws -> Int
    typealias UploadItem = @Sendable (
        RemoteFileLocalUploadPlanItem,
        String,
        TransferProgressTracker
    ) async throws -> Void

    func uploadFiles(
        plans: [RemoteFileLocalUploadPlanItem],
        to directoryPath: String,
        onProgress: RemoteFileBrowserStore.TransferProgressCallback? = nil,
        countTransferUnits: CountTransferUnits,
        uploadItem: UploadItem
    ) async throws {
        guard !plans.isEmpty else { return }

        let destinationDirectory = RemoteFilePath.normalize(directoryPath)
        let urls = plans.map(\.sourceURL)
        let progressTracker = TransferProgressTracker(
            totalUnitCount: try await countTransferUnits(urls),
            onProgress: onProgress
        )

        for plan in plans {
            try Task.checkCancellation()
            try await uploadItem(plan, destinationDirectory, progressTracker)
        }
    }
}
