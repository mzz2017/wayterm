import Foundation

// AVAudioEngine tap callbacks are synchronous and may arrive off the main
// actor. This registry lets AudioCaptureService own and await the main-actor
// buffer updates that were queued by those callbacks before stop/cancel returns.
nonisolated final class AudioBufferUpdateTaskRegistry: @unchecked Sendable {
    private final class Record {
        var task: Task<Void, Never>?
    }

    private let lock = NSLock()
    private var records: [UUID: Record] = [:]

    @discardableResult
    func track(_ operation: @escaping @MainActor @Sendable () async -> Void) -> UUID {
        let requestID = UUID()
        let record = Record()

        lock.lock()
        records[requestID] = record
        let task = Task { @MainActor [weak self] in
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
