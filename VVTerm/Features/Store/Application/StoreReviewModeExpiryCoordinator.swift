import Foundation

@MainActor
final class StoreReviewModeExpiryCoordinator {
    typealias StoreReviewModeExpirySleepAction = @Sendable (Duration) async -> Void
    typealias StoreReviewModeExpiryAction = @MainActor () async -> Void

    nonisolated private let cancellationBox = StoreTaskCancellationBox()
    private let sleepAction: StoreReviewModeExpirySleepAction
    private var expiryTask: Task<Void, Never>?
    private var requestID: UUID?
    private var supersededExpiryTasks: [UUID: Task<Void, Never>] = [:]

    init(
        sleepAction: @escaping StoreReviewModeExpirySleepAction = { duration in
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
    func scheduleExpiry(
        at expirationDate: Date,
        operation: @escaping StoreReviewModeExpiryAction
    ) -> UUID {
        if let supersededRequestID = requestID,
           let supersededTask = expiryTask {
            supersededExpiryTasks[supersededRequestID] = supersededTask
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
                    self.expiryTask = nil
                    self.cancellationBox.clear()
                }
                self.supersededExpiryTasks[requestID] = nil
            }

            await self.sleepAction(.nanoseconds(delayNanoseconds))
            guard !Task.isCancelled else { return }
            guard self.requestID == requestID else { return }

            await operation()
        }

        if self.requestID == requestID {
            expiryTask = task
            cancellationBox.set(task)
        }
        return requestID
    }

    func waitForExpiry(_ requestID: UUID) async {
        if self.requestID == requestID {
            await expiryTask?.value
            return
        }

        await supersededExpiryTasks[requestID]?.value
    }

    func cancelAll() {
        cancellationBox.cancel()
    }

    nonisolated func cancelAllFromAnyContext() {
        cancellationBox.cancel()
    }

    func cancelAllAndWait() async {
        let tasks = [expiryTask].compactMap { $0 } + Array(supersededExpiryTasks.values)
        cancellationBox.cancel()
        for task in tasks {
            await task.value
        }
        expiryTask = nil
        requestID = nil
        supersededExpiryTasks.removeAll()
        cancellationBox.clear()
    }
}
