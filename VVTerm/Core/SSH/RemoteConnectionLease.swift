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

nonisolated struct RemoteConnectionLease: Sendable {
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
        switch ownership {
        case .borrowed:
            self.state = RemoteConnectionLeaseStateRegistry.shared.state(forBorrowedClient: client)
        case .owned:
            self.state = RemoteConnectionLeaseState()
        }
    }

    func close() async {
        await state.close(client: client, ownership: ownership)
    }

    func withExclusiveClient<T: Sendable>(
        _ operation: @Sendable (any RemoteConnectionLeaseClient) async throws -> T
    ) async throws -> T {
        try await state.withExclusiveClient(client: client, operation)
    }
}

nonisolated struct RemoteConnectionLeaseProvider {
    private let provider: @MainActor (UUID) -> RemoteConnectionLease?

    init(_ provider: @escaping @MainActor (UUID) -> RemoteConnectionLease?) {
        self.provider = provider
    }

    @MainActor
    func lease(for serverId: UUID) -> RemoteConnectionLease? {
        provider(serverId)
    }

    static let none = RemoteConnectionLeaseProvider { _ in nil }
}

extension SSHClient: RemoteConnectionLeaseClient {}

private nonisolated final class RemoteConnectionLeaseStateRegistry: @unchecked Sendable {
    static let shared = RemoteConnectionLeaseStateRegistry()

    private let lock = NSLock()
    private let borrowedStates = NSMapTable<AnyObject, RemoteConnectionLeaseStateBox>(
        keyOptions: [.weakMemory, .objectPointerPersonality],
        valueOptions: [.strongMemory]
    )

    func state(forBorrowedClient client: any RemoteConnectionLeaseClient) -> RemoteConnectionLeaseState {
        let key = client as AnyObject

        lock.lock()
        defer { lock.unlock() }

        if let box = borrowedStates.object(forKey: key) {
            return box.state
        }

        let box = RemoteConnectionLeaseStateBox()
        borrowedStates.setObject(box, forKey: key)
        return box.state
    }
}

private nonisolated final class RemoteConnectionLeaseStateBox {
    let state = RemoteConnectionLeaseState()
}

private actor RemoteConnectionLeaseState {
    private enum CloseState {
        case open
        case closing
        case closed
    }

    private struct OperationWaiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private var closeState: CloseState = .open
    private var isOperationInFlight = false
    private var operationWaiters: [OperationWaiter] = []
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []
    private var closeCompletionWaiters: [CheckedContinuation<Void, Never>] = []

    func withExclusiveClient<T: Sendable>(
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
        guard case .owned = ownership else {
            await waitForExclusiveOperationsToFinish()
            return
        }

        switch closeState {
        case .open:
            closeState = .closing
        case .closing:
            await waitForCloseToFinish()
            return
        case .closed:
            return
        }

        cancelQueuedOperationWaiters()
        await waitForExclusiveOperationsToFinish()
        await client.disconnect()
        finishClose()
    }

    private func beginExclusiveOperation() async throws {
        guard closeState == .open else {
            throw CancellationError()
        }

        if !isOperationInFlight {
            isOperationInFlight = true
            return
        }

        let waiterId = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard closeState == .open else {
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
        if closeState != .open {
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

    private func waitForCloseToFinish() async {
        guard closeState == .closing else { return }

        await withCheckedContinuation { continuation in
            closeCompletionWaiters.append(continuation)
        }
    }

    private func finishClose() {
        closeState = .closed
        resumeCloseCompletionWaiters()
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

    private func resumeCloseCompletionWaiters() {
        let waiters = closeCompletionWaiters
        closeCompletionWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}
