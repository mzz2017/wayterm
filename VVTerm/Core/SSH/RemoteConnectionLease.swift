import Foundation

enum RemoteConnectionLeaseOwnership: Equatable, Sendable {
    case borrowed
    case owned
}

nonisolated protocol RemoteConnectionLeaseClient: AnyObject, RemoteCommandExecuting {
    func upload(
        _ data: Data,
        to path: String,
        permissions: Int32,
        strategy: SSHUploadStrategy
    ) async throws
    func disconnect() async
}

struct RemoteConnectionLease: Sendable {
    let client: any RemoteConnectionLeaseClient
    let ownership: RemoteConnectionLeaseOwnership
    private let state: RemoteConnectionLeaseState

    var commandExecutor: any RemoteCommandExecuting {
        client
    }

    init(
        client: any RemoteConnectionLeaseClient,
        ownership: RemoteConnectionLeaseOwnership
    ) {
        self.client = client
        self.ownership = ownership
        self.state = RemoteConnectionLeaseState()
    }

    func close() async {
        await state.close(client: client, ownership: ownership)
    }

    func withExclusiveClient<T>(
        _ operation: @Sendable (any RemoteConnectionLeaseClient) async throws -> T
    ) async throws -> T {
        try await state.withExclusiveClient(client: client, operation)
    }
}

@MainActor
struct RemoteConnectionLeaseProvider {
    private let provider: @MainActor (UUID) -> RemoteConnectionLease?

    init(_ provider: @escaping @MainActor (UUID) -> RemoteConnectionLease?) {
        self.provider = provider
    }

    func lease(for serverId: UUID) -> RemoteConnectionLease? {
        provider(serverId)
    }

    static let none = RemoteConnectionLeaseProvider { _ in nil }
}

extension SSHClient: RemoteConnectionLeaseClient {}

private actor RemoteConnectionLeaseState {
    private struct OperationWaiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private var didClose = false
    private var isOperationInFlight = false
    private var operationWaiters: [OperationWaiter] = []
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []

    func withExclusiveClient<T>(
        client: any RemoteConnectionLeaseClient,
        _ operation: @Sendable (any RemoteConnectionLeaseClient) async throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        try await beginExclusiveOperation()

        do {
            try Task.checkCancellation()
            let result = try await operation(client)
            finishExclusiveOperation()
            return result
        } catch {
            finishExclusiveOperation()
            throw error
        }
    }

    func close(
        client: any RemoteConnectionLeaseClient,
        ownership: RemoteConnectionLeaseOwnership
    ) async {
        guard !didClose else { return }
        didClose = true
        cancelQueuedOperationWaiters()
        await waitForExclusiveOperationsToFinish()

        guard case .owned = ownership else { return }
        await client.disconnect()
    }

    private func beginExclusiveOperation() async throws {
        guard !didClose else {
            throw CancellationError()
        }

        if !isOperationInFlight {
            isOperationInFlight = true
            return
        }

        let waiterId = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard !didClose else {
                    continuation.resume(throwing: CancellationError())
                    return
                }

                operationWaiters.append(
                    OperationWaiter(id: waiterId, continuation: continuation)
                )
            }
        } onCancel: {
            Task {
                await self.cancelOperationWaiter(waiterId)
            }
        }
    }

    private func finishExclusiveOperation() {
        if didClose {
            isOperationInFlight = false
            cancelQueuedOperationWaiters()
            resumeCloseWaiters()
            return
        }

        if operationWaiters.isEmpty {
            isOperationInFlight = false
            resumeCloseWaiters()
            return
        }

        let next = operationWaiters.removeFirst()
        next.continuation.resume()
    }

    private func waitForExclusiveOperationsToFinish() async {
        guard isOperationInFlight else { return }

        await withCheckedContinuation { continuation in
            closeWaiters.append(continuation)
        }
    }

    private func cancelOperationWaiter(_ waiterId: UUID) {
        guard let index = operationWaiters.firstIndex(where: { $0.id == waiterId }) else {
            return
        }

        let waiter = operationWaiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func cancelQueuedOperationWaiters() {
        let waiters = operationWaiters
        operationWaiters.removeAll()
        for waiter in waiters {
            waiter.continuation.resume(throwing: CancellationError())
        }
    }

    private func resumeCloseWaiters() {
        let waiters = closeWaiters
        closeWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}
