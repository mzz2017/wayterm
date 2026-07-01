import Foundation

nonisolated struct SSHAuthenticationLease: Sendable {
    private let key: String
    private let gate: SSHAuthenticationGate

    fileprivate init(key: String, gate: SSHAuthenticationGate) {
        self.key = key
        self.gate = gate
    }

    func release() async {
        await gate.releaseLease(for: key)
    }
}

actor SSHAuthenticationGate {
    static let shared = SSHAuthenticationGate()

    private var activeKeys: Set<String> = []
    private var waiterQueues = SSHAuthenticationWaiterQueues()

    func acquireLease(for key: String) async throws -> SSHAuthenticationLease {
        try await acquire(key)
        do {
            try Task.checkCancellation()
            return SSHAuthenticationLease(key: key, gate: self)
        } catch {
            release(key)
            throw error
        }
    }

    fileprivate func releaseLease(for key: String) {
        release(key)
    }

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
                waiterQueues.enqueue(
                    SSHAuthenticationWaiter(id: waiterId) { resolution in
                        switch resolution {
                        case .acquired:
                            continuation.resume()
                        case .canceled:
                            continuation.resume(throwing: CancellationError())
                        }
                    },
                    for: key
                )
            }
        } onCancel: {
            Task {
                await self.cancelWaiter(waiterId, for: key)
            }
        }
    }

    private func cancelWaiter(_ waiterId: UUID, for key: String) {
        waiterQueues.remove(id: waiterId, for: key)?.cancel()
    }

    private func release(_ key: String) {
        guard let next = waiterQueues.popFirst(for: key) else {
            activeKeys.remove(key)
            return
        }

        next.resume()
    }
}
