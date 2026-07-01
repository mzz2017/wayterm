import Foundation

@MainActor
final class StoreReviewModeExpiryCoordinator {
    typealias StoreReviewModeExpirySleepAction = @Sendable (Duration) async -> Void
    typealias StoreReviewModeExpiryAction = @MainActor () async -> Void

    nonisolated private let cancellationBox = StoreTaskCancellationBox()
    private let sleepAction: StoreReviewModeExpirySleepAction
    private var expiryTask: Task<Void, Never>?
    private var requestID: UUID?

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
        guard self.requestID == requestID else { return }
        await expiryTask?.value
    }

    func cancelAll() {
        cancellationBox.cancel()
    }

    nonisolated func cancelAllFromAnyContext() {
        cancellationBox.cancel()
    }

    func cancelAllAndWait() async {
        let task = expiryTask
        cancellationBox.cancel()
        await task?.value
        expiryTask = nil
        requestID = nil
        cancellationBox.clear()
    }
}
