import Foundation

@MainActor
final class RemoteFileRequestLifecycleCoordinator {
    private struct MutationRequest {
        let serverId: UUID?
        let task: Task<Void, Never>
        var isCancelled: Bool
    }

    private struct TransferRequest {
        let serverId: UUID?
        let task: Task<Void, Never>
        var isCancelled: Bool
    }

    private var mutationRequests: [UUID: MutationRequest] = [:]
    private var transferRequests: [UUID: TransferRequest] = [:]
    private var transferCancellationTasks: [UUID: Task<Void, Never>] = [:]

    var pendingMutationRequestIDs: Set<UUID> {
        Set(mutationRequests.compactMap { requestID, request in
            request.isCancelled ? nil : requestID
        })
    }

    var pendingTransferRequestIDs: Set<UUID> {
        Set(transferRequests.compactMap { requestID, request in
            request.isCancelled ? nil : requestID
        })
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
    func requestTransfer<Result>(
        serverId: UUID? = nil,
        operation: @escaping @MainActor @Sendable (@escaping @MainActor @Sendable (RemoteFileBrowserStore.TransferProgress) -> Void) async throws -> Result,
        onProgress: @escaping @MainActor @Sendable (RemoteFileBrowserStore.TransferProgress) -> Void = { _ in },
        onSuccess: @escaping @MainActor @Sendable (Result) -> Void,
        onFailure: @escaping @MainActor @Sendable (Error) -> Void = { _ in },
        onCancel: @escaping @MainActor @Sendable () -> Void = {}
    ) -> UUID {
        let requestID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                transferRequests.removeValue(forKey: requestID)
            }

            do {
                let result = try await operation { progress in
                    guard !Task.isCancelled, !self.isTransferRequestCancelled(requestID) else { return }
                    onProgress(progress)
                }
                guard !Task.isCancelled, !isTransferRequestCancelled(requestID) else {
                    onCancel()
                    return
                }
                onSuccess(result)
            } catch is CancellationError {
                // Disconnect-driven cancellation is lifecycle state, not a user-facing transfer failure.
                onCancel()
            } catch {
                guard !Task.isCancelled, !isTransferRequestCancelled(requestID) else {
                    onCancel()
                    return
                }
                onFailure(error)
            }
        }

        transferRequests[requestID] = TransferRequest(serverId: serverId, task: task, isCancelled: false)
        return requestID
    }

    func waitForTransferRequest(_ requestID: UUID) async {
        await transferRequests[requestID]?.task.value
    }

    @discardableResult
    func cancelTransferRequest(_ requestID: UUID) -> Task<Void, Never>? {
        guard var request = transferRequests[requestID] else { return nil }
        request.isCancelled = true
        transferRequests[requestID] = request
        request.task.cancel()
        return request.task
    }

    @discardableResult
    func cancelTransferRequestAndTrackCompletion(_ requestID: UUID) -> Task<Void, Never>? {
        if let task = transferCancellationTasks[requestID] {
            return task
        }
        guard let transferTask = cancelTransferRequest(requestID) else { return nil }

        let cancellationTask = Task { @MainActor [self] in
            await transferTask.value
            transferCancellationTasks.removeValue(forKey: requestID)
        }
        transferCancellationTasks[requestID] = cancellationTask
        return cancellationTask
    }

    func waitForTransferCancellationTasks() async {
        while true {
            let tasks = Array(transferCancellationTasks.values)
            guard !tasks.isEmpty else { return }
            for task in tasks {
                await task.value
            }
        }
    }

    @discardableResult
    func cancelTransferRequests(for serverId: UUID) -> [Task<Void, Never>] {
        var canceledTasks: [Task<Void, Never>] = []
        for (requestID, request) in transferRequests where request.serverId == serverId {
            var canceledRequest = request
            canceledRequest.isCancelled = true
            transferRequests[requestID] = canceledRequest
            request.task.cancel()
            canceledTasks.append(request.task)
        }
        return canceledTasks
    }

    @discardableResult
    func cancelAllTransferRequests() -> [Task<Void, Never>] {
        var canceledTasks: [Task<Void, Never>] = []
        for (requestID, request) in transferRequests {
            var canceledRequest = request
            canceledRequest.isCancelled = true
            transferRequests[requestID] = canceledRequest
            request.task.cancel()
            canceledTasks.append(request.task)
        }
        return canceledTasks
    }

    private func isMutationRequestCancelled(_ requestID: UUID) -> Bool {
        mutationRequests[requestID]?.isCancelled ?? true
    }

    private func isTransferRequestCancelled(_ requestID: UUID) -> Bool {
        transferRequests[requestID]?.isCancelled ?? true
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
