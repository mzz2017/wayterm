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

extension SSHClient: RemoteConnectionLeaseClient {}

private actor RemoteConnectionLeaseState {
    private var didClose = false
    private var isOperationInFlight = false
    private var operationWaiters: [CheckedContinuation<Void, Never>] = []
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
        await waitForExclusiveOperationsToFinish()

        guard ownership == .owned else { return }
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

        await withCheckedContinuation { continuation in
            operationWaiters.append(continuation)
        }
    }

    private func finishExclusiveOperation() {
        if operationWaiters.isEmpty {
            isOperationInFlight = false
            let waiters = closeWaiters
            closeWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
            return
        }

        let next = operationWaiters.removeFirst()
        next.resume()
    }

    private func waitForExclusiveOperationsToFinish() async {
        guard isOperationInFlight else { return }

        await withCheckedContinuation { continuation in
            closeWaiters.append(continuation)
        }
    }
}
