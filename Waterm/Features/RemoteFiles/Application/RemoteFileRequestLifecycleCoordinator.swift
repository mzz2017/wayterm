import Foundation

@MainActor
final class RemoteFileRequestLifecycleCoordinator {
    private struct MutationRequest {
        let serverId: UUID?
        let task: Task<Void, Never>
        var isCancelled: Bool
    }

    private var mutationRequests: [UUID: MutationRequest] = [:]
    private let transferCoordinator = RemoteFileTransferRequestLifecycleCoordinator()

    var pendingMutationRequestIDs: Set<UUID> {
        Set(mutationRequests.compactMap { requestID, request in
            request.isCancelled ? nil : requestID
        })
    }

    var pendingTransferRequestIDs: Set<UUID> {
        transferCoordinator.pendingRequestIDs
    }

    @discardableResult
    func requestMutation<Result>(
        serverId: UUID? = nil,
        operation: @escaping @MainActor () async throws -> Result,
        onSuccess: @escaping @MainActor (Result) -> Void,
        onFailure: @escaping @MainActor (Error) -> Void = { _ in }
    ) -> UUID {
        let requestID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                mutationRequests.removeValue(forKey: requestID)
            }

            do {
                let result = try await operation()
                guard !Task.isCancelled, !isMutationRequestCancelled(requestID) else { return }
                onSuccess(result)
            } catch is CancellationError {
                // Disconnect-driven cancellation is lifecycle state, not a user-facing mutation failure.
            } catch {
                guard !Task.isCancelled, !isMutationRequestCancelled(requestID) else { return }
                onFailure(error)
            }
        }

        mutationRequests[requestID] = MutationRequest(serverId: serverId, task: task, isCancelled: false)
        return requestID
    }

    func waitForMutationRequest(_ requestID: UUID) async {
        await mutationRequests[requestID]?.task.value
    }

    @discardableResult
    func cancelMutationRequests(for serverId: UUID) -> [Task<Void, Never>] {
        var canceledTasks: [Task<Void, Never>] = []
        for (requestID, request) in mutationRequests where request.serverId == serverId {
            var canceledRequest = request
            canceledRequest.isCancelled = true
            mutationRequests[requestID] = canceledRequest
            request.task.cancel()
            canceledTasks.append(request.task)
        }
        return canceledTasks
    }

    @discardableResult
    func cancelAllMutationRequests() -> [Task<Void, Never>] {
        var canceledTasks: [Task<Void, Never>] = []
        for (requestID, request) in mutationRequests {
            var canceledRequest = request
            canceledRequest.isCancelled = true
            mutationRequests[requestID] = canceledRequest
            request.task.cancel()
            canceledTasks.append(request.task)
        }
        return canceledTasks
    }

    @discardableResult
    func requestTransfer<Result: Sendable>(
        serverId: UUID? = nil,
        operation: @escaping @Sendable (@escaping @Sendable (RemoteFileBrowserStore.TransferProgress) async -> Void) async throws -> Result,
        onProgress: @escaping @MainActor @Sendable (RemoteFileBrowserStore.TransferProgress) -> Void = { _ in },
        onSuccess: @escaping @MainActor @Sendable (Result) -> Void,
        onFailure: @escaping @MainActor @Sendable (Error) -> Void = { _ in },
        onCancel: @escaping @MainActor @Sendable () -> Void = {}
    ) -> UUID {
        transferCoordinator.requestTransfer(
            serverIds: Set(serverId.map { [$0] } ?? []),
            operation: { onProgress, _ in
                try await operation(onProgress)
            },
            onProgress: onProgress,
            onSuccess: onSuccess,
            onFailure: onFailure,
            onCancel: onCancel
        )
    }

    @discardableResult
    func requestTransfer<Result: Sendable>(
        serverIds: Set<UUID>,
        operation: @escaping @Sendable (
            @escaping @Sendable (RemoteFileBrowserStore.TransferProgress) async -> Void,
            @escaping @Sendable (Set<UUID>) async -> Void
        ) async throws -> Result,
        onProgress: @escaping @MainActor @Sendable (RemoteFileBrowserStore.TransferProgress) -> Void = { _ in },
        onSuccess: @escaping @MainActor @Sendable (Result) -> Void,
        onFailure: @escaping @MainActor @Sendable (Error) -> Void = { _ in },
        onCancel: @escaping @MainActor @Sendable () -> Void = {}
    ) -> UUID {
        transferCoordinator.requestTransfer(
            serverIds: serverIds,
            operation: operation,
            onProgress: onProgress,
            onSuccess: onSuccess,
            onFailure: onFailure,
            onCancel: onCancel
        )
    }

    func waitForTransferRequest(_ requestID: UUID) async {
        await transferCoordinator.waitForTransferRequest(requestID)
    }

    @discardableResult
    func cancelTransferRequest(_ requestID: UUID) -> Task<Void, Never>? {
        transferCoordinator.cancelTransferRequest(requestID)
    }

    @discardableResult
    func cancelTransferRequestAndTrackCompletion(_ requestID: UUID) -> Task<Void, Never>? {
        transferCoordinator.cancelTransferRequestAndTrackCompletion(requestID)
    }

    func waitForTransferCancellationTasks() async {
        await transferCoordinator.waitForTransferCancellationTasks()
    }

    @discardableResult
    func cancelTransferRequests(for serverId: UUID) -> [Task<Void, Never>] {
        transferCoordinator.cancelTransferRequests(for: serverId)
    }

    @discardableResult
    func cancelAllTransferRequests() -> [Task<Void, Never>] {
        transferCoordinator.cancelAllTransferRequests()
    }

    private func isMutationRequestCancelled(_ requestID: UUID) -> Bool {
        mutationRequests[requestID]?.isCancelled ?? true
    }

}

nonisolated final class RemoteFileTransferCancellationIntentCoordinator: @unchecked Sendable {
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
        let task = Task { @MainActor [self] in
            await operation()
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
