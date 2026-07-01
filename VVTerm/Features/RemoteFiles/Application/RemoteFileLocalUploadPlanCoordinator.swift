import Foundation

nonisolated struct RemoteFileLocalUploadPlanCoordinator {
    typealias LocalItemInfoLoader = @Sendable (URL) async throws -> RemoteFileLocalItemInfo

    let conflictResolver: RemoteFileConflictResolver

    init(conflictResolver: RemoteFileConflictResolver = RemoteFileConflictResolver()) {
        self.conflictResolver = conflictResolver
    }

    func prepareLocalUploadPlan(
        at urls: [URL],
        to directoryPath: String,
        using service: any RemoteFileService,
        localItemInfo: LocalItemInfoLoader
    ) async throws -> [RemoteFileBrowserStore.LocalUploadPlanCandidate] {
        let destinationDirectory = RemoteFilePath.normalize(directoryPath)
        var reservedNames: Set<String> = []
        var candidates: [RemoteFileBrowserStore.LocalUploadPlanCandidate] = []

        for url in urls {
            try Task.checkCancellation()
            let itemInfo = try await localItemInfo(url)
            let originalName = itemInfo.name
            let resolution = try await conflictResolver.resolveName(
                for: originalName,
                in: destinationDirectory,
                policy: .keepBoth,
                using: service,
                reservedNames: &reservedNames
            )
            candidates.append(
                RemoteFileBrowserStore.LocalUploadPlanCandidate(
                    sourceURL: url,
                    originalName: originalName,
                    existingEntry: resolution.existingEntry,
                    suggestedName: resolution.hasConflict ? resolution.resolvedName : nil
                )
            )
        }

        return candidates
    }
}
