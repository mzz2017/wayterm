import Foundation

nonisolated struct SSHPendingConnectCleanup {
    private struct Timeout: Error {}

    private let timeout: Duration

    init(timeout: Duration) {
        self.timeout = timeout
    }

    @discardableResult
    func waitForPendingTask<T: Sendable>(_ task: Task<T, Error>?) async -> Bool {
        guard let task else { return false }

        do {
            try await AsyncTimeoutGate.run(
                timeout: timeout,
                timeoutError: { Timeout() },
                operation: {
                    _ = try await task.value
                }
            )
            return false
        } catch is Timeout {
            task.cancel()
            return true
        } catch {
            return false
        }
    }
}
