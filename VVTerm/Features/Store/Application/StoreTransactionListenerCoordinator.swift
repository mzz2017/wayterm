import Foundation

@MainActor
final class StoreTransactionListenerCoordinator {
    typealias StoreTransactionListenerAction = @MainActor () async -> Void

    nonisolated private let cancellationBox = StoreTaskCancellationBox()
    private var listenerTask: Task<Void, Never>?
    private var requestID: UUID?

    var pendingRequestIDs: Set<UUID> {
        guard let requestID else { return [] }
        return [requestID]
    }

    @discardableResult
    func startListening(operation: @escaping StoreTransactionListenerAction) -> UUID {
        cancellationBox.cancel()

        let requestID = UUID()
        self.requestID = requestID

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.requestID == requestID {
                    self.requestID = nil
                    self.listenerTask = nil
                    self.cancellationBox.clear()
                }
            }

            guard !Task.isCancelled else { return }
            await operation()
        }

        if self.requestID == requestID {
            listenerTask = task
            cancellationBox.set(task)
        }
        return requestID
    }

    func waitForListener(_ requestID: UUID) async {
        guard self.requestID == requestID else { return }
        await listenerTask?.value
    }

    func cancelAll() {
        cancellationBox.cancel()
    }

    nonisolated func cancelAllFromAnyContext() {
        cancellationBox.cancel()
    }

    func cancelAllAndWait() async {
        let task = listenerTask
        cancellationBox.cancel()
        await task?.value
        listenerTask = nil
        requestID = nil
        cancellationBox.clear()
    }
}
