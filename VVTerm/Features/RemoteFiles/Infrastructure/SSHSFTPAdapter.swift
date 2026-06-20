import Foundation

@MainActor
final class SSHSFTPAdapter {
    typealias BorrowedLeaseProvider = @MainActor (UUID) -> RemoteConnectionLease?
    typealias CredentialsProvider = @MainActor (Server) throws -> ServerCredentials
    typealias OwnedClientFactory = @MainActor () -> any SFTPRemoteFileClient

    private struct ClientRegistration {
        let client: any SFTPRemoteFileClient
        let lease: RemoteConnectionLease

        var clientID: ObjectIdentifier {
            ObjectIdentifier(client)
        }
    }

    private var clients: [UUID: ClientRegistration] = [:]
    private let borrowedLeaseProvider: BorrowedLeaseProvider
    private let credentialsProvider: CredentialsProvider
    private let ownedClientFactory: OwnedClientFactory

    init(
        borrowedLeaseProvider: @escaping BorrowedLeaseProvider = { serverId in
            ConnectionSessionManager.shared.sharedStatsLease(for: serverId)
                ?? TerminalTabManager.shared.sharedStatsLease(for: serverId)
        },
        credentialsProvider: @escaping CredentialsProvider = { server in
            try KeychainManager.shared.getCredentials(for: server)
        },
        ownedClientFactory: @escaping OwnedClientFactory = {
            SSHClient()
        }
    ) {
        self.borrowedLeaseProvider = borrowedLeaseProvider
        self.credentialsProvider = credentialsProvider
        self.ownedClientFactory = ownedClientFactory
    }

    func withService<T>(
        for server: Server,
        operation: @escaping (any RemoteFileService) async throws -> T
    ) async throws -> T {
        let registration = clientRegistration(for: server)
        let credentials = try credentialsProvider(server)

        do {
            return try await registration.lease.withExclusiveClient { _ in
                try await registration.client.connectForRemoteFileLease(
                    to: server,
                    credentials: credentials
                )
                return try await operation(SFTPRemoteFileService(client: registration.client))
            }
        } catch {
            if registration.lease.ownership == .borrowed {
                clients.removeValue(forKey: server.id)
            }
            throw error
        }
    }

    func disconnect(serverId: UUID) async {
        guard let registration = clients.removeValue(forKey: serverId) else { return }
        await registration.lease.close()
    }

    private func borrowedLease(for serverId: UUID) -> RemoteConnectionLease? {
        borrowedLeaseProvider(serverId)
    }

    private func clientRegistration(for server: Server) -> ClientRegistration {
        if let borrowedLease = borrowedLease(for: server.id),
           let borrowedClient = borrowedLease.client as? any SFTPRemoteFileClient {
            if let existing = clients[server.id],
               existing.clientID == ObjectIdentifier(borrowedClient) {
                return existing
            }

            let registration = ClientRegistration(
                client: borrowedClient,
                lease: borrowedLease
            )
            clients[server.id] = registration
            return registration
        }

        if let existing = clients[server.id], existing.lease.ownership == .owned {
            return existing
        }

        let client = ownedClientFactory()
        let registration = ClientRegistration(
            client: client,
            lease: RemoteConnectionLease(client: client, ownership: .owned)
        )
        clients[server.id] = registration
        return registration
    }
}
