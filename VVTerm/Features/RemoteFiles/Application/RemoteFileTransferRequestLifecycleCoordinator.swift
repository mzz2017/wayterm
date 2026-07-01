import Foundation

@MainActor
final class RemoteFileTransferRequestLifecycleCoordinator {
    private struct TransferRequest {
        var serverIds: Set<UUID>
        let cancellationGenerationSnapshot: [UUID: Int]
        let task: Task<Void, Never>
        var isCancelled: Bool
    }

    private var transferRequests: [UUID: TransferRequest] = [:]
    private var transferCancellationTasks: [UUID: Task<Void, Never>] = [:]
    private var transferServerCancellationGenerations: [UUID: Int] = [:]

    var pendingRequestIDs: Set<UUID> {
        Set(transferRequests.compactMap { requestID, request in
            request.isCancelled ? nil : requestID
        })
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
        requestTransfer(
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
    func requestTransfer<Result>(
        serverIds: Set<UUID>,
        operation: @escaping @MainActor @Sendable (
            @escaping @MainActor @Sendable (RemoteFileBrowserStore.TransferProgress) -> Void,
            @escaping @MainActor @Sendable (Set<UUID>) -> Void
        ) async throws -> Result,
        onProgress: @escaping @MainActor @Sendable (RemoteFileBrowserStore.TransferProgress) -> Void = { _ in },
        onSuccess: @escaping @MainActor @Sendable (Result) -> Void,
        onFailure: @escaping @MainActor @Sendable (Error) -> Void = { _ in },
        onCancel: @escaping @MainActor @Sendable () -> Void = {}
    ) -> UUID {
        let requestID = UUID()
        let cancellationGenerationSnapshot = transferServerCancellationGenerations
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                transferRequests.removeValue(forKey: requestID)
            }

            do {
                let result = try await operation(
                    { progress in
                        guard !Task.isCancelled, !self.isTransferRequestCancelled(requestID) else { return }
                        onProgress(progress)
                    },
                    { serverIds in
                        self.bindTransferRequest(requestID, to: serverIds)
                    }
                )
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

        transferRequests[requestID] = TransferRequest(
            serverIds: serverIds,
            cancellationGenerationSnapshot: cancellationGenerationSnapshot,
            task: task,
            isCancelled: false
        )
        return requestID
    }

    private func bindTransferRequest(_ requestID: UUID, to serverIds: Set<UUID>) {
        guard !serverIds.isEmpty, var request = transferRequests[requestID], !request.isCancelled else { return }
        request.serverIds.formUnion(serverIds)
        if serverIds.contains(where: { serverId in
            transferServerCancellationGenerations[serverId, default: 0]
                != request.cancellationGenerationSnapshot[serverId, default: 0]
        }) {
            request.isCancelled = true
            request.task.cancel()
            trackTransferCancellationCompletion(requestID, task: request.task)
        }
        transferRequests[requestID] = request
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
        return trackTransferCancellationCompletion(requestID, task: transferTask)
    }

    @discardableResult
    private func trackTransferCancellationCompletion(
        _ requestID: UUID,
        task transferTask: Task<Void, Never>
    ) -> Task<Void, Never> {
        if let task = transferCancellationTasks[requestID] {
            return task
        }
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
        transferServerCancellationGenerations[serverId, default: 0] += 1
        for (requestID, request) in transferRequests where request.serverIds.contains(serverId) {
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

    private func isTransferRequestCancelled(_ requestID: UUID) -> Bool {
        transferRequests[requestID]?.isCancelled ?? true
    }
}
