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

    private(set) var connectionTestFailure: ServerConnectionTestFailure?

    private let connectionTesting: any ServerConnectionTesting
    private var connectionTestRequests: [UUID: Task<Void, Never>] = [:]

    var pendingConnectionTestRequestIDs: Set<UUID> {
        Set(connectionTestRequests.keys)
    }

    init(connectionTesting: (any ServerConnectionTesting)? = nil) {
        self.connectionTesting = connectionTesting ?? ServerConnectionOperationTester()
    }

    @discardableResult
    func requestConnectionTest(
        server: Server,
        credentials: ServerCredentials,
        onSucceeded: @escaping @MainActor () -> Void = {},
        onFailed: @escaping @MainActor (Error) -> Void = { _ in },
        onCompleted: @escaping @MainActor () -> Void = {}
    ) -> UUID {
        let requestID = UUID()
        connectionTestFailure = nil

        let task = Task { [weak self, connectionTesting] in
            guard let self else { return }
            defer {
                connectionTestRequests.removeValue(forKey: requestID)
                onCompleted()
            }

            do {
                try await connectionTesting.testConnection(server: server, credentials: credentials)
                onSucceeded()
            } catch is CancellationError {
                // User-initiated cancellation is lifecycle state, not a failed connection test.
            } catch {
                connectionTestFailure = ServerConnectionTestFailure(
                    operation: .testConnection(server.id),
                    error: error
                )
                onFailed(error)
            }
        }

        connectionTestRequests[requestID] = task
        return requestID
    }

    func waitForConnectionTestRequest(_ requestID: UUID) async {
        await connectionTestRequests[requestID]?.value
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
