import Foundation

@MainActor
final class StoreSubscriptionExpirationRefreshCoordinator {
    typealias StoreSubscriptionExpirationSleepAction = @Sendable (Duration) async -> Void
    typealias StoreSubscriptionExpirationRefreshAction = @MainActor () async -> Void

    nonisolated private let cancellationBox = StoreTaskCancellationBox()
    private let sleepAction: StoreSubscriptionExpirationSleepAction
    private var refreshTask: Task<Void, Never>?
    private var requestID: UUID?
    private var supersededRefreshTasks: [UUID: Task<Void, Never>] = [:]

    init(
        sleepAction: @escaping StoreSubscriptionExpirationSleepAction = { duration in
            try? await Task.sleep(for: duration)
        }
    ) {
        self.sleepAction = sleepAction
    }

    var pendingRequestIDs: Set<UUID> {
        guard let requestID else { return [] }
        return [requestID]
    }

    @discardableResult
    func scheduleRefresh(
        at expirationDate: Date,
        operation: @escaping StoreSubscriptionExpirationRefreshAction
    ) -> UUID {
        if let supersededRequestID = requestID,
           let supersededTask = refreshTask {
            supersededRefreshTasks[supersededRequestID] = supersededTask
        }
        cancellationBox.cancel()

        let requestID = UUID()
        self.requestID = requestID
        let delay = max(0, expirationDate.timeIntervalSinceNow)
        let delayNanoseconds = Int64(delay * 1_000_000_000)

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.requestID == requestID {
                    self.requestID = nil
                    self.refreshTask = nil
                    self.cancellationBox.clear()
                }
                self.supersededRefreshTasks[requestID] = nil
            }

            await self.sleepAction(.nanoseconds(delayNanoseconds))
            guard !Task.isCancelled else { return }
            guard self.requestID == requestID else { return }

            await operation()
        }

        if self.requestID == requestID {
            refreshTask = task
            cancellationBox.set(task)
        }
        return requestID
    }

    func waitForRefresh(_ requestID: UUID) async {
        if self.requestID == requestID {
            await refreshTask?.value
            return
        }

        await supersededRefreshTasks[requestID]?.value
    }

    func cancelAll() {
        cancellationBox.cancel()
    }

    nonisolated func cancelAllFromAnyContext() {
        cancellationBox.cancel()
    }

    func cancelAllAndWait() async {
        let tasks = [refreshTask].compactMap { $0 } + Array(supersededRefreshTasks.values)
        cancellationBox.cancel()
        for task in tasks {
            await task.value
        }
        refreshTask = nil
        requestID = nil
        supersededRefreshTasks.removeAll()
        cancellationBox.clear()
    }
}
