import Foundation

nonisolated enum AsyncTimeoutGate {
    static func run<T: Sendable>(
        timeout: Duration,
        timeoutError: @escaping @Sendable () -> any Error,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let taskBox = TimeoutTaskBox()
        return try await withTaskCancellationHandler {
            defer { taskBox.cancelAll() }
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
                let gate = TimeoutContinuation(continuation)
                let operationTask = Task {
                    do {
                        let value = try await operation()
                        await gate.resume(returning: value)
                    } catch {
                        await gate.resume(throwing: error)
                    }
                }
                let timeoutTask = Task {
                    do {
                        try await Task.sleep(for: timeout)
                        await gate.resume(throwing: timeoutError())
                    } catch is CancellationError {
                        // The operation completed before the timeout fired.
                    } catch {
                        await gate.resume(throwing: error)
                    }
                }
                taskBox.store([operationTask, timeoutTask])
            }
        } onCancel: {
            taskBox.cancelAll()
        }
    }

    static func waitForTask<T: Sendable>(
        _ task: Task<T, Error>,
        timeout: Duration,
        timeoutError: @escaping @Sendable () -> any Error
    ) async throws {
        do {
            try await run(timeout: timeout, timeoutError: timeoutError) {
                _ = try await task.value
            }
        } catch {
            task.cancel()
            throw error
        }
    }
}

private actor TimeoutContinuation<T: Sendable> {
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    func resume(returning value: T) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: value)
    }

    func resume(throwing error: any Error) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(throwing: error)
    }
}

nonisolated private final class TimeoutTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [Task<Void, Never>] = []
    private var isCancelled = false

    func store(_ tasks: [Task<Void, Never>]) {
        lock.lock()
        let shouldCancel = isCancelled
        if !shouldCancel {
            self.tasks = tasks
        }
        lock.unlock()

        if shouldCancel {
            tasks.forEach { $0.cancel() }
        }
    }

    func cancelAll() {
        lock.lock()
        isCancelled = true
        let tasks = self.tasks
        self.tasks = []
        lock.unlock()

        tasks.forEach { $0.cancel() }
    }
}
