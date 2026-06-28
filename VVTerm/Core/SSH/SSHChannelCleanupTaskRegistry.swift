//
//  SSHChannelCleanupTaskRegistry.swift
//  VVTerm
//
//  SSH session channel cleanup task tracking.
//

import Foundation

// AsyncStream termination and cancellation handlers are synchronous,
// nonisolated callbacks, so this tiny registry uses a lock to let SSHSession
// own and later await channel cleanup tasks without escaping actor state.
nonisolated final class SSHChannelCleanupTaskRegistry: @unchecked Sendable {
    private final class Record {
        var task: Task<Void, Never>?
    }

    private let lock = NSLock()
    private var records: [UUID: Record] = [:]

    @discardableResult
    func track(_ operation: @escaping @Sendable () async -> Void) -> UUID {
        let requestID = UUID()
        let record = Record()

        lock.lock()
        records[requestID] = record
        // Keep task publication atomic with record insertion so waiters cannot
        // observe an empty task list while cleanup has already been registered.
        let task = Task.detached { [weak self] in
            await operation()
            self?.remove(requestID)
        }
        record.task = task
        lock.unlock()

        return requestID
    }

    func tasks() -> [Task<Void, Never>] {
        lock.lock()
        defer { lock.unlock() }
        return records.values.compactMap(\.task)
    }

    private func remove(_ requestID: UUID) {
        lock.lock()
        records.removeValue(forKey: requestID)
        lock.unlock()
    }
}
