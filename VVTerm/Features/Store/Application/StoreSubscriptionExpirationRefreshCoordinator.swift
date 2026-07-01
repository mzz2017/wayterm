import Foundation

@MainActor
final class StoreSubscriptionExpirationRefreshCoordinator {
    typealias StoreSubscriptionExpirationSleepAction = @Sendable (Duration) async -> Void
    typealias StoreSubscriptionExpirationRefreshAction = @MainActor () async -> Void

    nonisolated private let cancellationBox = StoreTaskCancellationBox()
    private let sleepAction: StoreSubscriptionExpirationSleepAction
    private var refreshTask: Task<Void, Never>?
    private var requestID: UUID?

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
        guard self.requestID == requestID else { return }
        await refreshTask?.value
    }

    func cancelAll() {
        cancellationBox.cancel()
    }

    nonisolated func cancelAllFromAnyContext() {
        cancellationBox.cancel()
    }

    func cancelAllAndWait() async {
        let task = refreshTask
        cancellationBox.cancel()
        await task?.value
        refreshTask = nil
        requestID = nil
        cancellationBox.clear()
    }
}
