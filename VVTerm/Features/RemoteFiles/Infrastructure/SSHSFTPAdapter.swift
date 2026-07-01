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

    private struct PendingClientRegistration {
        let id: UUID
        let task: Task<ClientRegistration, Error>
    }

    private var clients: [UUID: ClientRegistration] = [:]
    private var pendingClientRegistrations: [UUID: PendingClientRegistration] = [:]
    private let remoteConnectionLeaseProvider: RemoteConnectionLeaseProvider
    private let credentialsProvider: CredentialsProvider
    private let ownedClientFactory: OwnedClientFactory

    init(
        remoteConnectionLeaseProvider: RemoteConnectionLeaseProvider = .none,
        credentialsProvider: @escaping CredentialsProvider,
        ownedClientFactory: @escaping OwnedClientFactory = {
            SSHClient()
        }
    ) {
        self.remoteConnectionLeaseProvider = remoteConnectionLeaseProvider
        self.credentialsProvider = credentialsProvider
        self.ownedClientFactory = ownedClientFactory
    }

    convenience init(
        borrowedLeaseProvider: @escaping BorrowedLeaseProvider,
        credentialsProvider: @escaping CredentialsProvider,
        ownedClientFactory: @escaping OwnedClientFactory = {
            SSHClient()
        }
    ) {
        self.init(
            remoteConnectionLeaseProvider: RemoteConnectionLeaseProvider(borrowedLeaseProvider),
            credentialsProvider: credentialsProvider,
            ownedClientFactory: ownedClientFactory
        )
    }

    func withService<T: Sendable>(
        for server: Server,
        operation: @Sendable @escaping (any RemoteFileService) async throws -> T
    ) async throws -> T {
        let registration = try await clientRegistration(for: server)
        let credentials = try credentialsProvider(server)
        guard isCurrentRegistration(registration, for: server.id) else {
            throw CancellationError()
        }

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
                removeBorrowedRegistrationIfCurrent(registration, for: server.id)
            }
            throw error
        }
    }

    func disconnect(serverId: UUID) async {
        let pendingRegistration = pendingClientRegistrations.removeValue(forKey: serverId)
        pendingRegistration?.task.cancel()
        let registration = clients.removeValue(forKey: serverId)
        if let registration {
            await registration.lease.close()
        }
        if let pendingRegistration {
            if case .success(let replacement) = await pendingRegistration.task.result {
                await replacement.lease.close()
            }
        }
    }

    func disconnectAll() async {
        let pendingRegistrations = Array(pendingClientRegistrations.values)
        pendingClientRegistrations.removeAll()
        for pendingRegistration in pendingRegistrations {
            pendingRegistration.task.cancel()
        }
        let registrations = Array(clients.values)
        clients.removeAll()
        let closeTasks = registrations.map { registration in
            Task { @MainActor in
                await registration.lease.close()
            }
        }

        for closeTask in closeTasks {
            await closeTask.value
        }
        for pendingRegistration in pendingRegistrations {
            if case .success(let replacement) = await pendingRegistration.task.result {
                await replacement.lease.close()
            }
        }
    }

    private func borrowedLease(for serverId: UUID) -> RemoteConnectionLease? {
        remoteConnectionLeaseProvider.lease(for: serverId)
    }

    private func clientRegistration(for server: Server) async throws -> ClientRegistration {
        if let pendingRegistration = pendingClientRegistrations[server.id] {
            return try await pendingRegistration.task.value
        }

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
            return try await replaceRegistration(for: server.id, with: registration)
        }

        if let existing = clients[server.id], existing.lease.ownership == .owned {
            return existing
        }

        let client = ownedClientFactory()
        let registration = ClientRegistration(
            client: client,
            lease: RemoteConnectionLease(client: client, ownership: .owned)
        )
        return try await replaceRegistration(for: server.id, with: registration)
    }

    private func replaceRegistration(
        for serverId: UUID,
        with replacement: ClientRegistration
    ) async throws -> ClientRegistration {
        if let pendingRegistration = pendingClientRegistrations[serverId] {
            return try await pendingRegistration.task.value
        }

        let existing = clients[serverId]
        let replacementID = UUID()
        let replacementTask = Task { @MainActor in
            if let existing {
                await existing.lease.close()
            }
            do {
                try Task.checkCancellation()
            } catch {
                await replacement.lease.close()
                throw error
            }
            guard pendingClientRegistrations[serverId]?.id == replacementID else {
                await replacement.lease.close()
                throw CancellationError()
            }
            clients[serverId] = replacement
            pendingClientRegistrations.removeValue(forKey: serverId)
            return replacement
        }
        pendingClientRegistrations[serverId] = PendingClientRegistration(
            id: replacementID,
            task: replacementTask
        )

        return try await replacementTask.value
    }

    private func isCurrentRegistration(
        _ registration: ClientRegistration,
        for serverId: UUID
    ) -> Bool {
        guard let current = clients[serverId] else { return false }
        return current.clientID == registration.clientID
    }

    private func removeBorrowedRegistrationIfCurrent(
        _ registration: ClientRegistration,
        for serverId: UUID
    ) {
        guard let current = clients[serverId],
              current.lease.ownership == .borrowed,
              current.clientID == registration.clientID
        else { return }
        clients.removeValue(forKey: serverId)
    }
}

extension SSHSFTPAdapter: RemoteFileServiceAccessing {}
