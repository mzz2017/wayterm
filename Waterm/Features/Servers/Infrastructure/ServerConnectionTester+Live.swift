import Foundation

extension SSHConnectionOperationService: ServerConnectionOperationServing {
    func withTemporaryConnection<T: Sendable>(
        server: Server,
        credentials: ServerCredentials,
        operation: @Sendable @escaping (SSHClient) async throws -> T
    ) async throws -> T {
        try await withTemporaryConnection(
            target: server.sshConnectionTarget,
            credentials: credentials,
            operation: operation
        )
    }
}

extension ServerConnectionTester {
    static let shared = ServerConnectionTester()

    convenience init() {
        self.init(connectionTesting: ServerConnectionOperationTester.live)
    }
}

extension ServerConnectionOperationTester {
    static var live: ServerConnectionOperationTester {
        ServerConnectionOperationTester(
            connectionService: SSHConnectionOperationService.shared,
            moshBootstrapper: LiveServerConnectionMoshBootstrapper()
        )
    }
}

final class LiveServerConnectionMoshBootstrapper: ServerConnectionMoshBootstrapping {
    private let manager: RemoteMoshManager

    init(manager: RemoteMoshManager = .shared) {
        self.manager = manager
    }

    func bootstrapConnectInfo(
        using executor: any RemoteCommandExecuting,
        startCommand: String?,
        portRange: ClosedRange<Int>
    ) async throws {
        _ = try await manager.bootstrapConnectInfo(
            using: executor,
            startCommand: startCommand,
            portRange: portRange
        )
    }
}
