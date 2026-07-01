import Foundation
import MoshCore

nonisolated final class SSHMoshShellRuntime: @unchecked Sendable {
    let session: MoshClientSession
    private let lock = NSLock()
    private var streamTask: Task<Void, Never>?

    init(session: MoshClientSession) {
        self.session = session
    }

    func setStreamTask(_ task: Task<Void, Never>) {
        lock.lock()
        streamTask = task
        lock.unlock()
    }

    func cancelStreamTask() {
        lock.lock()
        let task = streamTask
        streamTask = nil
        lock.unlock()
        task?.cancel()
    }

    #if DEBUG
    var streamTaskForTesting: Task<Void, Never>? {
        lock.lock()
        defer { lock.unlock() }
        return streamTask
    }
    #endif
}
