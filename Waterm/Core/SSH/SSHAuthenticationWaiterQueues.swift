import Foundation

nonisolated struct SSHAuthenticationWaiter: Sendable {
    enum Resolution: Sendable {
        case acquired(UUID)
        case canceled
    }

    let id: UUID
    private let resolve: @Sendable (Resolution) -> Void

    init(id: UUID, resolve: @escaping @Sendable (Resolution) -> Void) {
        self.id = id
        self.resolve = resolve
    }

    func resume(leaseID: UUID) {
        resolve(.acquired(leaseID))
    }

    func cancel() {
        resolve(.canceled)
    }
}

nonisolated struct SSHAuthenticationWaiterQueues {
    private var waitersByKey: [String: [SSHAuthenticationWaiter]] = [:]

    mutating func enqueue(_ waiter: SSHAuthenticationWaiter, for key: String) {
        waitersByKey[key, default: []].append(waiter)
    }

    mutating func popFirst(for key: String) -> SSHAuthenticationWaiter? {
        guard var waiters = waitersByKey[key], !waiters.isEmpty else {
            return nil
        }

        let waiter = waiters.removeFirst()
        update(waiters, for: key)
        return waiter
    }

    mutating func remove(id: UUID, for key: String) -> SSHAuthenticationWaiter? {
        guard var waiters = waitersByKey[key],
              let index = waiters.firstIndex(where: { $0.id == id }) else {
            return nil
        }

        let waiter = waiters.remove(at: index)
        update(waiters, for: key)
        return waiter
    }

    private mutating func update(_ waiters: [SSHAuthenticationWaiter], for key: String) {
        if waiters.isEmpty {
            waitersByKey.removeValue(forKey: key)
        } else {
            waitersByKey[key] = waiters
        }
    }
}
