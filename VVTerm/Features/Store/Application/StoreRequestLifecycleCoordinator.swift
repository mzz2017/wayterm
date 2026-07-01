import Foundation

@MainActor
final class StoreRequestLifecycleCoordinator {
    nonisolated private let cancellationBox = StoreRequestLifecycleCancellationBox()
    private var requestTask: Task<Void, Never>?
    private var requestID: UUID?
    private(set) var lastRequestFailure: Error?

    var pendingRequestIDs: Set<UUID> {
        guard let requestID else { return [] }
        return [requestID]
    }

    @discardableResult
    func request(operation: @escaping @MainActor () async throws -> Void) -> UUID {
        if let requestID {
            return requestID
        }

        let requestID = UUID()
        self.requestID = requestID
        lastRequestFailure = nil

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.requestID == requestID {
                    self.requestID = nil
                    self.requestTask = nil
                    self.cancellationBox.clear()
                }
            }

            do {
                try await operation()
            } catch is CancellationError {
                return
            } catch {
                self.lastRequestFailure = error
            }
        }

        if self.requestID == requestID {
            requestTask = task
            cancellationBox.set(task)
        }
        return requestID
    }

    func waitForRequest(_ requestID: UUID) async {
        guard self.requestID == requestID else { return }
        await requestTask?.value
    }

    func cancelRequest(_ requestID: UUID) {
        guard self.requestID == requestID else { return }
        requestTask?.cancel()
    }

    func cancelAll() {
        cancellationBox.cancel()
    }

    nonisolated func cancelAllFromAnyContext() {
        cancellationBox.cancel()
    }

    func cancelAllAndWait() async {
        let task = requestTask
        cancellationBox.cancel()
        await task?.value
        requestTask = nil
        requestID = nil
        cancellationBox.clear()
    }
}

nonisolated final class StoreRequestLifecycleCancellationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    func set(_ task: Task<Void, Never>) {
        lock.lock()
        self.task = task
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        let task = task
        lock.unlock()
        task?.cancel()
    }

    func clear() {
        lock.lock()
        task = nil
        lock.unlock()
    }
}
