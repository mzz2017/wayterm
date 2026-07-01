import Foundation

@MainActor
final class StoreBackgroundRefreshCoordinator {
    nonisolated enum RefreshKind: Hashable, Sendable {
        case startup
        case reviewMode
    }

    typealias StoreBackgroundRefreshAction = @MainActor () async -> Void

    nonisolated private let cancellationBoxes: [RefreshKind: StoreTaskCancellationBox] = [
        .startup: StoreTaskCancellationBox(),
        .reviewMode: StoreTaskCancellationBox()
    ]
    private var refreshTasks: [RefreshKind: Task<Void, Never>] = [:]
    private var requestIDs: [RefreshKind: UUID] = [:]
    private var supersededRefreshTasks: [UUID: Task<Void, Never>] = [:]

    func pendingRequestIDs(for kind: RefreshKind) -> Set<UUID> {
        guard let requestID = requestIDs[kind] else { return [] }
        return [requestID]
    }

    @discardableResult
    func startRefresh(
        kind: RefreshKind,
        operation: @escaping StoreBackgroundRefreshAction
    ) -> UUID {
        if let supersededRequestID = requestIDs[kind],
           let supersededTask = refreshTasks[kind] {
            supersededRefreshTasks[supersededRequestID] = supersededTask
        }
        cancellationBoxes[kind]?.cancel()

        let requestID = UUID()
        requestIDs[kind] = requestID

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.requestIDs[kind] == requestID {
                    self.requestIDs[kind] = nil
                    self.refreshTasks[kind] = nil
                    self.cancellationBoxes[kind]?.clear()
                }
                self.supersededRefreshTasks[requestID] = nil
            }

            guard !Task.isCancelled else { return }
            await operation()
        }

        if requestIDs[kind] == requestID {
            refreshTasks[kind] = task
            cancellationBoxes[kind]?.set(task)
        }
        return requestID
    }

    func waitForRefresh(kind: RefreshKind, _ requestID: UUID) async {
        if requestIDs[kind] == requestID {
            await refreshTasks[kind]?.value
            return
        }

        await supersededRefreshTasks[requestID]?.value
    }

    func cancelAll() {
        cancellationBoxes.values.forEach { $0.cancel() }
    }

    nonisolated func cancelAllFromAnyContext() {
        cancellationBoxes.values.forEach { $0.cancel() }
    }

    func cancelAllAndWait() async {
        let tasks = Array(refreshTasks.values) + Array(supersededRefreshTasks.values)
        cancellationBoxes.values.forEach { $0.cancel() }
        for task in tasks {
            await task.value
        }
        refreshTasks.removeAll()
        supersededRefreshTasks.removeAll()
        requestIDs.removeAll()
        cancellationBoxes.values.forEach { $0.clear() }
    }
}
