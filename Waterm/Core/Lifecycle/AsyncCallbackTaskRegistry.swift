import Foundation

// Synchronous callbacks cannot await lifecycle cleanup directly. This registry
// lets the stable owner publish that async work before the callback returns,
// then await all published tasks before reporting teardown complete.
nonisolated final class AsyncCallbackTaskRegistry: @unchecked Sendable {
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
        let task = Task { [self] in
            await operation()
            remove(requestID)
        }
        record.task = task
        lock.unlock()

        return requestID
    }

    @discardableResult
    func trackDetached(_ operation: @escaping @Sendable () async -> Void) -> UUID {
        let requestID = UUID()
        let record = Record()

        lock.lock()
        records[requestID] = record
        let task = Task.detached { [self] in
            await operation()
            remove(requestID)
        }
        record.task = task
        lock.unlock()

        return requestID
    }

    @discardableResult
    func trackMainActor(_ operation: @escaping @MainActor @Sendable () async -> Void) -> UUID {
        let requestID = UUID()
        let record = Record()

        lock.lock()
        records[requestID] = record
        let task = Task { @MainActor [self] in
            await operation()
            remove(requestID)
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

    func waitForAll() async {
        while true {
            let tasks = tasks()
            guard !tasks.isEmpty else { return }
            for task in tasks {
                await task.value
            }
        }
    }

    private func remove(_ requestID: UUID) {
        lock.lock()
        records.removeValue(forKey: requestID)
        lock.unlock()
    }
}
