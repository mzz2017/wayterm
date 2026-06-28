//
//  SSHMoshTeardownTaskRegistry.swift
//  VVTerm
//
//  Tracks Mosh stream teardown tasks that begin outside SSHClient actor isolation.
//

import Foundation

// Mosh stream termination is a synchronous callback outside SSHClient actor
// isolation; this registry lets the client own and await teardown tasks without
// exposing actor-isolated mosh runtime state.
nonisolated final class SSHMoshTeardownTaskRegistry: @unchecked Sendable {
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
        // observe an empty task list while teardown has already been registered.
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
