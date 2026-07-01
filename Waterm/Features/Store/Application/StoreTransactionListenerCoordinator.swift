import Foundation

@MainActor
final class StoreTransactionListenerCoordinator {
    typealias StoreTransactionListenerAction = @MainActor () async -> Void

    nonisolated private let cancellationBox = StoreTaskCancellationBox()
    private var listenerTask: Task<Void, Never>?
    private var requestID: UUID?
    private var supersededListenerTasks: [UUID: Task<Void, Never>] = [:]

    var pendingRequestIDs: Set<UUID> {
        guard let requestID else { return [] }
        return [requestID]
    }

    @discardableResult
    func startListening(operation: @escaping StoreTransactionListenerAction) -> UUID {
        if let supersededRequestID = requestID,
           let supersededTask = listenerTask {
            supersededListenerTasks[supersededRequestID] = supersededTask
        }
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
                self.supersededListenerTasks[requestID] = nil
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
        if self.requestID == requestID {
            await listenerTask?.value
            return
        }

        await supersededListenerTasks[requestID]?.value
    }

    func cancelAll() {
        cancellationBox.cancel()
    }

    nonisolated func cancelAllFromAnyContext() {
        cancellationBox.cancel()
    }

    func cancelAllAndWait() async {
        let tasks = [listenerTask].compactMap { $0 } + Array(supersededListenerTasks.values)
        cancellationBox.cancel()
        for task in tasks {
            await task.value
        }
        listenerTask = nil
        requestID = nil
        supersededListenerTasks.removeAll()
        cancellationBox.clear()
    }
}
