import Foundation

@MainActor
protocol ServerConnectionTesting: AnyObject {
    func testConnection(server: Server, credentials: ServerCredentials) async throws
}

struct ServerConnectionTestFailure: Identifiable, Equatable {
    enum Operation: Equatable {
        case testConnection(UUID)
    }

    let id: UUID
    let operation: Operation
    let message: String

    init(id: UUID = UUID(), operation: Operation, error: Error) {
        self.id = id
        self.operation = operation
        self.message = error.localizedDescription
    }
}

@MainActor
final class ServerConnectionTester {
    static let shared = ServerConnectionTester()

    private struct ConnectionTestRequest {
        let task: Task<Void, Never>
        var isCancelled: Bool
    }

    private(set) var connectionTestFailure: ServerConnectionTestFailure?

    private let connectionTesting: any ServerConnectionTesting
    private var connectionTestRequests: [UUID: ConnectionTestRequest] = [:]

    var pendingConnectionTestRequestIDs: Set<UUID> {
        Set(connectionTestRequests.compactMap { requestID, request in
            request.isCancelled ? nil : requestID
        })
    }

    init(connectionTesting: (any ServerConnectionTesting)? = nil) {
        self.connectionTesting = connectionTesting ?? ServerConnectionOperationTester()
    }

    @discardableResult
    func requestConnectionTest(
        id requestID: UUID = UUID(),
        server: Server,
        credentials: ServerCredentials,
        onSucceeded: @escaping @MainActor () -> Void = {},
        onFailed: @escaping @MainActor (Error) -> Void = { _ in },
        onCompleted: @escaping @MainActor () -> Void = {}
    ) -> UUID {
        connectionTestFailure = nil

        let task = Task { @MainActor [weak self, connectionTesting] in
            guard let self else { return }
            defer {
                connectionTestRequests.removeValue(forKey: requestID)
                onCompleted()
            }

            do {
                try await connectionTesting.testConnection(server: server, credentials: credentials)
                guard !Task.isCancelled, !isConnectionTestRequestCancelled(requestID) else { return }
                onSucceeded()
            } catch is CancellationError {
                // User-initiated cancellation is lifecycle state, not a failed connection test.
            } catch {
                guard !Task.isCancelled, !isConnectionTestRequestCancelled(requestID) else { return }
                connectionTestFailure = ServerConnectionTestFailure(
                    operation: .testConnection(server.id),
                    error: error
                )
                onFailed(error)
            }
        }

        connectionTestRequests[requestID] = ConnectionTestRequest(task: task, isCancelled: false)
        return requestID
    }

    func waitForConnectionTestRequest(_ requestID: UUID) async {
        await connectionTestRequests[requestID]?.task.value
    }

    func cancelConnectionTestRequest(_ requestID: UUID) {
        guard var request = connectionTestRequests[requestID] else { return }
        request.isCancelled = true
        connectionTestRequests[requestID] = request
        request.task.cancel()
    }

    private func isConnectionTestRequestCancelled(_ requestID: UUID) -> Bool {
        connectionTestRequests[requestID]?.isCancelled ?? true
    }
}

@MainActor
final class ServerConnectionOperationTester: ServerConnectionTesting {
    func testConnection(server: Server, credentials: ServerCredentials) async throws {
        try await SSHConnectionOperationService.shared.withTemporaryConnection(
            server: server,
            credentials: credentials
        ) { client in
            if server.connectionMode == .mosh {
                _ = try await RemoteMoshManager.shared.bootstrapConnectInfo(
                    using: client,
                    startCommand: "exec true",
                    portRange: 60001...61000
                )
            }
        }
    }
}
