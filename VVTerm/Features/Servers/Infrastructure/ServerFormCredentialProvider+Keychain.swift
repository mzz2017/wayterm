import Foundation

extension KeychainManager: ServerFormCredentialLibrary {
    func storedSSHKeyData(for keyId: UUID) throws -> (key: Data, passphrase: String?)? {
        try getStoredSSHKeyData(for: keyId)
    }

    func credentials(for server: Server) throws -> ServerCredentials {
        try getCredentials(for: server)
    }
}

extension ServerFormCredentialProvider {
    static let shared = ServerFormCredentialProvider(library: KeychainManager.shared)
}
