import Foundation

actor SSHAuthenticationGate {
    static let shared = SSHAuthenticationGate()

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private var activeKeys: Set<String> = []
    private var waitersByKey: [String: [Waiter]] = [:]

    func withExclusiveAccess<T>(
        for key: String,
        operation: () async throws -> T
    ) async throws -> T {
        try await acquire(key)
        defer { release(key) }
        try Task.checkCancellation()
        return try await operation()
    }

    private func acquire(_ key: String) async throws {
        if activeKeys.insert(key).inserted {
            return
        }

        let waiterId = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waitersByKey[key, default: []].append(
                    Waiter(id: waiterId, continuation: continuation)
                )
            }
        } onCancel: {
            Task {
                await self.cancelWaiter(waiterId, for: key)
            }
        }
    }

    private func cancelWaiter(_ waiterId: UUID, for key: String) {
        guard var waiters = waitersByKey[key],
              let index = waiters.firstIndex(where: { $0.id == waiterId }) else {
            return
        }

        let waiter = waiters.remove(at: index)
        if waiters.isEmpty {
            waitersByKey.removeValue(forKey: key)
        } else {
            waitersByKey[key] = waiters
        }
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func release(_ key: String) {
        guard var waiters = waitersByKey[key], !waiters.isEmpty else {
            activeKeys.remove(key)
            return
        }

        let next = waiters.removeFirst()
        if waiters.isEmpty {
            waitersByKey.removeValue(forKey: key)
        } else {
            waitersByKey[key] = waiters
        }
        next.continuation.resume()
    }
}
