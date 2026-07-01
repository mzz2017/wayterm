import Foundation

actor SSHKeepAliveCoordinator {
    typealias SleepAction = @Sendable (Duration) async -> Void
    typealias KeepAliveAction = @Sendable () async -> Void

    private let sleepAction: SleepAction
    private var task: Task<Void, Never>?
    private var requestID: UUID?

    init(
        _ sleepAction: @escaping SleepAction = { duration in
            try? await Task.sleep(for: duration)
        }
    ) {
        self.sleepAction = sleepAction
    }

    var pendingRequestIDs: Set<UUID> {
        guard let requestID else { return [] }
        return [requestID]
    }

    @discardableResult
    func start(
        interval: TimeInterval,
        operation: @escaping KeepAliveAction
    ) -> UUID {
        task?.cancel()

        let requestID = UUID()
        self.requestID = requestID
        let sleepAction = self.sleepAction
        let intervalNanoseconds = Int64(max(0, interval) * 1_000_000_000)
        let intervalDuration = Duration.nanoseconds(intervalNanoseconds)

        let task = Task { [weak self] in
            while !Task.isCancelled {
                await sleepAction(intervalDuration)
                guard !Task.isCancelled else { break }
                guard await self?.isCurrent(requestID) == true else { break }
                await operation()
            }

            await self?.clearIfCurrent(requestID)
        }

        if self.requestID == requestID {
            self.task = task
        }
        return requestID
    }

    func cancelAllAndWait() async {
        let task = self.task
        task?.cancel()
        await task?.value
        self.task = nil
        requestID = nil
    }

    private func isCurrent(_ requestID: UUID) -> Bool {
        self.requestID == requestID
    }

    private func clearIfCurrent(_ requestID: UUID) {
        guard self.requestID == requestID else { return }
        self.requestID = nil
        task = nil
    }
}
