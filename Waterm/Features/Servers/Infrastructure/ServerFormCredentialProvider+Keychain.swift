import Foundation

extension KeychainManager: ServerFormCredentialLibrary {
    func storedSSHKeyData(for keyId: UUID) throws -> (key: Data, passphrase: String?)? {
        try getStoredSSHKeyData(for: keyId)
    }

    func credentials(for server: Server) throws -> ServerCredentials {
        try getCredentials(for: credentialLookupRequest(for: server))
    }

    func getCredentials(for server: Server) throws -> ServerCredentials {
        try getCredentials(for: credentialLookupRequest(for: server))
    }

    private func credentialLookupRequest(for server: Server) -> KeychainCredentialLookupRequest {
        KeychainCredentialLookupRequest(
            serverId: server.id,
            authMethod: server.authMethod,
            connectionMode: server.connectionMode,
            cloudflareAccessMode: server.cloudflareAccessMode
        )
    }
}

extension ServerFormCredentialProvider {
    static let shared = ServerFormCredentialProvider(library: KeychainManager.shared)
}
