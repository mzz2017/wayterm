import Foundation
import CloudKit
import os.log

@MainActor
final class CloudKitSyncCoordinator {
    typealias PendingMutationSyncAction = @MainActor (PendingCloudKitMutation) async throws -> Void

    enum DrainState: Equatable {
        case idle
        case draining
        case drainAgainRequested
    }

    static let shared = CloudKitSyncCoordinator()

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "app.vivy.vvterm",
        category: "CloudKitSyncCoordinator"
    )
    private let queue: PendingCloudKitSyncQueue
    private var syncPendingMutation: PendingMutationSyncAction
    private var drainTask: Task<Void, Never>?
    private(set) var drainState: DrainState = .idle

    private init(
        queue: PendingCloudKitSyncQueue? = nil,
        syncPendingMutation: PendingMutationSyncAction? = nil
    ) {
        self.queue = queue ?? PendingCloudKitSyncQueue()
        self.syncPendingMutation = syncPendingMutation ?? Self.unconfiguredPendingMutationSync
    }

    #if DEBUG
    static func makeForTesting(
        storageKey: String,
        syncPendingMutation: @escaping PendingMutationSyncAction
    ) -> CloudKitSyncCoordinator {
        CloudKitSyncCoordinator(
            queue: PendingCloudKitSyncQueue(storageKey: storageKey),
            syncPendingMutation: syncPendingMutation
        )
    }
    #endif

    func snapshot() -> [PendingCloudKitMutation] {
        queue.snapshot()
    }

    func clearPendingMutations() {
        queue.removeAll()
    }

    func clearPendingMutations(for entities: Set<PendingCloudKitEntity>) {
        queue.removeAll { entities.contains($0.entity) }
    }

    func removePendingMutation(_ mutationID: UUID) {
        queue.remove(mutationID)
    }

    func enqueuePendingMutation(_ mutation: PendingCloudKitMutation) {
        queue.enqueue(mutation)
    }

    func configurePendingMutationSync(_ syncPendingMutation: @escaping PendingMutationSyncAction) {
        self.syncPendingMutation = syncPendingMutation
    }

    func drainPendingMutations() async {
        guard SyncSettings.isEnabled else { return }

        if let drainTask {
            drainState = .drainAgainRequested
            await drainTask.value
            return
        }

        drainState = .draining
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runPendingMutationDrain()
        }
        drainTask = task
        await task.value
    }

    private func runPendingMutationDrain() async {
        defer {
            drainTask = nil
            drainState = .idle
        }

        while true {
            let drainRequestedDuringIteration = drainState == .drainAgainRequested
            drainState = .draining
            let snapshot = queue.snapshot()
            guard !snapshot.isEmpty else { return }

            var didProgress = false
            let orderedMutations = snapshot.sorted(by: pendingSyncDrainOrder)

            for mutation in orderedMutations {
                guard queue.canAttempt(mutation, at: Date()) else {
                    continue
                }

                do {
                    try await syncPendingMutation(mutation)
                    queue.remove(mutation.id)
                    didProgress = true
                } catch {
                    if isIgnorableDeleteSyncError(error, for: mutation) {
                        queue.remove(mutation.id)
                        didProgress = true
                        continue
                    }

                    queue.recordFailure(for: mutation, error: error)
                    logger.warning(
                        "Pending CloudKit sync failed for \(mutation.entityDescription): \(error.localizedDescription)"
                    )

                    if shouldPausePendingSyncDrain(for: error) {
                        return
                    }
                }
            }

            if !didProgress {
                if drainState == .drainAgainRequested || drainRequestedDuringIteration {
                    continue
                }
                return
            }
        }
    }

    private func pendingSyncDrainOrder(_ lhs: PendingCloudKitMutation, _ rhs: PendingCloudKitMutation) -> Bool {
        if lhs.drainPriority != rhs.drainPriority {
            return lhs.drainPriority < rhs.drainPriority
        }

        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt < rhs.createdAt
        }

        return lhs.id.uuidString < rhs.id.uuidString
    }

    private func isIgnorableDeleteSyncError(_ error: Error, for mutation: PendingCloudKitMutation) -> Bool {
        guard mutation.operation == .delete else { return false }
        return isCloudKitMissingRecordError(error)
    }

    private func isCloudKitMissingRecordError(_ error: Error) -> Bool {
        guard let ckError = error as? CKError else { return false }

        switch ckError.code {
        case .unknownItem, .zoneNotFound:
            return true
        case .partialFailure:
            guard let partialErrors = ckError.userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: Error] else {
                return false
            }
            return partialErrors.values.contains { isCloudKitMissingRecordError($0) }
        default:
            return false
        }
    }

    private func shouldPausePendingSyncDrain(for error: Error) -> Bool {
        if let cloudKitError = error as? CloudKitError, cloudKitError == .notAvailable {
            return true
        }

        guard let ckError = error as? CKError else { return false }

        switch ckError.code {
        case .notAuthenticated, .permissionFailure, .quotaExceeded, .requestRateLimited,
             .serviceUnavailable, .networkUnavailable, .networkFailure:
            return true
        default:
            return false
        }
    }

    private static func unconfiguredPendingMutationSync(_ mutation: PendingCloudKitMutation) async throws {
        throw CloudKitPendingMutationSyncError.unconfigured(mutation.entityDescription)
    }

}

private enum CloudKitPendingMutationSyncError: LocalizedError {
    case unconfigured(String)

    var errorDescription: String? {
        switch self {
        case .unconfigured(let entityDescription):
            return "Pending CloudKit sync is not configured for \(entityDescription)"
        }
    }
}
