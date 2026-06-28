import Foundation

nonisolated final class GhosttySurfaceRegistration {
    private static let deferredUnregisterTasks = GhosttySurfaceDeferredUnregisterTaskRegistry()

    private weak var appWrapper: Ghostty.App?
    private var reference: Ghostty.SurfaceReference?

    @MainActor
    func register(_ surface: ghostty_surface_t, appWrapper: Ghostty.App?, terminalView: GhosttyTerminalView) {
        unregister()
        guard let appWrapper else { return }
        self.appWrapper = appWrapper
        reference = appWrapper.registerSurface(surface, terminalView: terminalView)
    }

    @MainActor
    func unregister() {
        if let appWrapper, let reference {
            appWrapper.unregisterSurface(reference)
        }
        appWrapper = nil
        reference = nil
    }

    @discardableResult
    nonisolated func unregisterLaterFromDeinit() -> UUID? {
        let appWrapper = appWrapper
        let reference = reference
        self.appWrapper = nil
        self.reference = nil

        guard let appWrapper, let reference else { return nil }
        return Self.deferredUnregisterTasks.track {
            appWrapper.unregisterSurface(reference)
        }
    }

    nonisolated static func waitForDeferredUnregisters() async {
        await deferredUnregisterTasks.waitForAll()
    }
}

nonisolated final class GhosttySurfaceDeferredUnregisterTaskRegistry: @unchecked Sendable {
    private final class Record {
        var task: Task<Void, Never>?
    }

    private let lock = NSLock()
    private var records: [UUID: Record] = [:]

    @discardableResult
    func track(_ operation: @escaping @MainActor @Sendable () -> Void) -> UUID {
        let requestID = UUID()
        let record = Record()

        lock.lock()
        records[requestID] = record
        let task = Task { @MainActor [self] in
            operation()
            remove(requestID)
        }
        record.task = task
        lock.unlock()

        return requestID
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

    private func tasks() -> [Task<Void, Never>] {
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
