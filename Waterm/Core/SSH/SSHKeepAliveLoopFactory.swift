import Foundation

nonisolated struct SSHKeepAliveLoopFactory {
    typealias SleepAction = @Sendable (Duration) async -> Void
    typealias KeepAliveAction = @Sendable () async -> Void
    typealias ContinuationCheck = @Sendable () async -> Bool
    typealias FinishAction = @Sendable () async -> Void

    private let sleepAction: SleepAction

    init(_ sleepAction: @escaping SleepAction = { duration in
        try? await Task.sleep(for: duration)
    }) {
        self.sleepAction = sleepAction
    }

    func makeLoop(
        interval: TimeInterval,
        shouldContinue: @escaping ContinuationCheck,
        operation: @escaping KeepAliveAction,
        onFinished: @escaping FinishAction
    ) -> Task<Void, Never> {
        let sleepAction = self.sleepAction
        let intervalNanoseconds = Int64(max(0, interval) * 1_000_000_000)
        let intervalDuration = Duration.nanoseconds(intervalNanoseconds)

        return Task {
            while !Task.isCancelled {
                await sleepAction(intervalDuration)
                guard !Task.isCancelled else { break }
                guard await shouldContinue() else { break }
                await operation()
            }

            await onFinished()
        }
    }
}
