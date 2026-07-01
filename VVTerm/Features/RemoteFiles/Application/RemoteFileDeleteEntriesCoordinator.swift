import Foundation

nonisolated struct RemoteFileDeleteEntriesCoordinator {
    struct Failure: Error {
        let didMutate: Bool
        let underlyingError: any Error
    }

    let deletionCoordinator: RemoteFileDeletionCoordinator

    init(deletionCoordinator: RemoteFileDeletionCoordinator = RemoteFileDeletionCoordinator()) {
        self.deletionCoordinator = deletionCoordinator
    }

    func deleteEntries(
        _ entries: [RemoteFileEntry],
        using service: any RemoteFileService
    ) async throws {
        guard !entries.isEmpty else { return }

        var didMutate = false

        do {
            for entry in entries {
                try Task.checkCancellation()
                try await deletionCoordinator.deleteEntry(entry, using: service) {
                    didMutate = true
                }
            }
        } catch {
            if didMutate {
                throw Failure(didMutate: true, underlyingError: error)
            }
            throw error
        }
    }
}
