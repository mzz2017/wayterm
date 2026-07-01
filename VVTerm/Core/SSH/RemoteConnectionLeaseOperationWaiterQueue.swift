import Foundation

nonisolated struct RemoteConnectionLeaseOperationWaiter: Sendable {
    enum Resolution: Sendable {
        case acquired
        case canceled
    }

    let id: UUID
    private let resolve: @Sendable (Resolution) -> Void

    init(id: UUID, resolve: @escaping @Sendable (Resolution) -> Void) {
        self.id = id
        self.resolve = resolve
    }

    func resume() {
        resolve(.acquired)
    }

    func cancel() {
        resolve(.canceled)
    }
}

nonisolated struct RemoteConnectionLeaseOperationWaiterQueue {
    private var waiters: [RemoteConnectionLeaseOperationWaiter] = []

    var isEmpty: Bool {
        waiters.isEmpty
    }

    mutating func enqueue(_ waiter: RemoteConnectionLeaseOperationWaiter) {
        waiters.append(waiter)
    }

    mutating func popFirst() -> RemoteConnectionLeaseOperationWaiter? {
        guard !waiters.isEmpty else { return nil }
        return waiters.removeFirst()
    }

    mutating func remove(id: UUID) -> RemoteConnectionLeaseOperationWaiter? {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            return nil
        }

        return waiters.remove(at: index)
    }

    mutating func removeAll() -> [RemoteConnectionLeaseOperationWaiter] {
        let removedWaiters = waiters
        waiters.removeAll()
        return removedWaiters
    }
}
