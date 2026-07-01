import Foundation

nonisolated struct SSHAuthenticationLease: Sendable {
    private let key: String
    private let leaseID: UUID
    private let gate: SSHAuthenticationGate

    fileprivate init(key: String, leaseID: UUID, gate: SSHAuthenticationGate) {
        self.key = key
        self.leaseID = leaseID
        self.gate = gate
    }

    func release() async {
        await gate.releaseLease(for: key, leaseID: leaseID)
    }
}

actor SSHAuthenticationGate {
    static let shared = SSHAuthenticationGate()

    private var activeLeasesByKey: [String: UUID] = [:]
    private var waiterQueues = SSHAuthenticationWaiterQueues()

    func acquireLease(for key: String) async throws -> SSHAuthenticationLease {
        let leaseID = try await acquire(key)
        do {
            try Task.checkCancellation()
            return SSHAuthenticationLease(key: key, leaseID: leaseID, gate: self)
        } catch {
            release(key, leaseID: leaseID)
            throw error
        }
    }

    fileprivate func releaseLease(for key: String, leaseID: UUID) {
        release(key, leaseID: leaseID)
    }

    func withExclusiveAccess<T>(
        for key: String,
        operation: () async throws -> T
    ) async throws -> T {
        let leaseID = try await acquire(key)
        defer { release(key, leaseID: leaseID) }
        try Task.checkCancellation()
        return try await operation()
    }

    private func acquire(_ key: String) async throws -> UUID {
        if activeLeasesByKey[key] == nil {
            let leaseID = UUID()
            activeLeasesByKey[key] = leaseID
            return leaseID
        }

        let waiterId = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiterQueues.enqueue(
                    SSHAuthenticationWaiter(id: waiterId) { resolution in
                        switch resolution {
                        case .acquired(let leaseID):
                            continuation.resume(returning: leaseID)
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

    private func release(_ key: String, leaseID: UUID) {
        guard activeLeasesByKey[key] == leaseID else { return }

        guard let next = waiterQueues.popFirst(for: key) else {
            activeLeasesByKey.removeValue(forKey: key)
            return
        }

        let nextLeaseID = UUID()
        activeLeasesByKey[key] = nextLeaseID
        next.resume(leaseID: nextLeaseID)
    }
}
