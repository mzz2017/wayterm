import Foundation

@MainActor
enum StatsSSHConnectionProvider {
    static func makeProvider() -> StatsConnectionProvider {
        StatsConnectionProvider { _, _ in
            makeOwnedConnection()
        }
    }

    private static func makeOwnedConnection() -> ServerStatsCollector.StatsConnection {
        let client = SSHClient()
        let lease = RemoteConnectionLease(client: client, ownership: .owned)
        return ServerStatsCollector.StatsConnection(lease: lease) { lease, server, credentials, operation in
            try await lease.withExclusiveClient { leasedClient in
                guard let sshClient = leasedClient as? SSHClient else {
                    try await operation(leasedClient)
                    return
                }

                try await SSHConnectionOperationService.shared.runWithConnection(
                    using: sshClient,
                    target: server.sshConnectionTarget,
                    credentials: credentials,
                    disconnectWhenDone: false
                ) { connectedClient in
                    try await operation(connectedClient)
                }
            }
        }
    }
}
