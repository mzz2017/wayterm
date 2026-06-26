import Foundation

protocol ServerFormCredentialLibrary: AnyObject {
    func storedSSHKeys() -> [SSHKeyEntry]
    func storedSSHKeyData(for keyId: UUID) throws -> (key: Data, passphrase: String?)?
    func credentials(for server: Server) throws -> ServerCredentials
}

struct ServerFormStoredSSHKeyMaterial: Equatable {
    let privateKey: String
    let passphrase: String?
    let publicKey: String?
}

enum ServerFormCredentialProviderError: LocalizedError, Equatable {
    case invalidStoredKeyEncoding(UUID)

    var errorDescription: String? {
        switch self {
        case .invalidStoredKeyEncoding:
            return String(localized: "Stored SSH key data could not be decoded.")
        }
    }
}

final class ServerFormCredentialProvider {
    private let library: any ServerFormCredentialLibrary

    init(library: any ServerFormCredentialLibrary) {
        self.library = library
    }

    func storedSSHKeys() -> [SSHKeyEntry] {
        library.storedSSHKeys()
    }

    func credentials(for server: Server) throws -> ServerCredentials {
        try library.credentials(for: server)
    }

    func storedSSHKeyMaterial(for entry: SSHKeyEntry) throws -> ServerFormStoredSSHKeyMaterial? {
        guard let keyData = try library.storedSSHKeyData(for: entry.id) else {
            return nil
        }
        guard let privateKey = String(data: keyData.key, encoding: .utf8) else {
            throw ServerFormCredentialProviderError.invalidStoredKeyEncoding(entry.id)
        }
        return ServerFormStoredSSHKeyMaterial(
            privateKey: privateKey,
            passphrase: keyData.passphrase,
            publicKey: entry.publicKey
        )
    }

    func matchingStoredSSHKey(
        in candidates: [SSHKeyEntry],
        privateKey: String,
        passphrase: String?,
        authMethod: AuthMethod
    ) -> SSHKeyEntry? {
        guard authMethod != .password, !privateKey.isEmpty else {
            return nil
        }

        for key in candidates {
            guard let material = try? storedSSHKeyMaterial(for: key),
                  material.privateKey == privateKey else {
                continue
            }

            if let storedPassphrase = material.passphrase,
               !storedPassphrase.isEmpty,
               storedPassphrase != passphrase {
                continue
            }

            return key
        }

        return nil
    }

    func matchingStoredSSHKey(
        privateKey: String,
        passphrase: String?,
        authMethod: AuthMethod
    ) -> SSHKeyEntry? {
        matchingStoredSSHKey(
            in: library.storedSSHKeys(),
            privateKey: privateKey,
            passphrase: passphrase,
            authMethod: authMethod
        )
    }
}
