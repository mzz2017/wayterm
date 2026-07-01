import Foundation

extension ServerManager {
    static func defaultDeletionTeardown(for _: Server) async {}

    static func defaultCredentialDeletion(for serverId: UUID) async throws {
        try ServerCredentialPersistence.shared.deleteCredentials(for: serverId)
    }

    static func defaultCredentialStore(for server: Server, credentials: ServerCredentials) throws {
        try ServerCredentialPersistence.shared.storeCredentials(for: server, credentials: credentials)
    }
}
