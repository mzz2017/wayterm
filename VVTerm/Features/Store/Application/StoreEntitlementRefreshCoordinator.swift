import Foundation

@MainActor
final class StoreEntitlementRefreshCoordinator {
    typealias StoreEntitlementRefreshAction = @MainActor () async -> Void

    nonisolated private let cancellationBox = StoreTaskCancellationBox()
    private let defaultRefreshAction: StoreEntitlementRefreshAction?
    private var refreshTask: Task<Void, Never>?
    private var refreshRequestID: UUID?
    private var shouldRefreshAfterCurrent = false

    init(refreshAction: StoreEntitlementRefreshAction? = nil) {
        defaultRefreshAction = refreshAction
    }

    var pendingRequestIDs: Set<UUID> {
        guard let refreshRequestID else { return [] }
        return [refreshRequestID]
    }

    @discardableResult
    func requestRefresh(
        reason: StoreEntitlementRefreshReason,
        operation: StoreEntitlementRefreshAction? = nil
    ) -> UUID {
        if let refreshRequestID {
            if reason == .subscriptionExpiration {
                shouldRefreshAfterCurrent = true
            }
            return refreshRequestID
        }

        let refreshAction = operation ?? defaultRefreshAction
        let requestID = UUID()
        refreshRequestID = requestID

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.refreshRequestID == requestID {
                    self.refreshRequestID = nil
                    self.refreshTask = nil
                    self.shouldRefreshAfterCurrent = false
                    self.cancellationBox.clear()
                }
            }

            repeat {
                self.shouldRefreshAfterCurrent = false
                guard !Task.isCancelled else { return }
                await refreshAction?()
                guard !Task.isCancelled else { return }
            } while self.shouldRefreshAfterCurrent
        }

        if refreshRequestID == requestID {
            refreshTask = task
            cancellationBox.set(task)
        }
        return requestID
    }

    func waitForRefresh(_ requestID: UUID) async {
        guard refreshRequestID == requestID else { return }
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
        refreshRequestID = nil
        shouldRefreshAfterCurrent = false
        cancellationBox.clear()
    }
}
