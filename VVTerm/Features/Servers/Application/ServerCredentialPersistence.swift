import Foundation

@MainActor
protocol ServerCredentialWritingLibrary: AnyObject {
    func deleteCredentials(for serverId: UUID) throws
    func storePassword(for serverId: UUID, password: String) throws
    func storeSSHKey(for serverId: UUID, privateKey: Data, passphrase: String?, publicKey: Data?) throws
    func storeCloudflareServiceToken(for serverId: UUID, clientID: String, clientSecret: String) throws
}

@MainActor
final class ServerCredentialPersistence {
    private let library: any ServerCredentialWritingLibrary

    init(library: any ServerCredentialWritingLibrary) {
        self.library = library
    }

    func deleteCredentials(for serverId: UUID) throws {
        try library.deleteCredentials(for: serverId)
    }

    func storeCredentials(for server: Server, credentials: ServerCredentials) throws {
        try library.deleteCredentials(for: server.id)

        if server.connectionMode != .tailscale {
            switch server.authMethod {
            case .password:
                if let password = credentials.password, !password.isEmpty {
                    try library.storePassword(for: server.id, password: password)
                }
            case .sshKey:
                if let sshKey = credentials.sshKey, !sshKey.isEmpty {
                    try library.storeSSHKey(
                        for: server.id,
                        privateKey: sshKey,
                        passphrase: nil,
                        publicKey: credentials.publicKey
                    )
                }
            case .sshKeyWithPassphrase:
                if let sshKey = credentials.sshKey, !sshKey.isEmpty {
                    let passphrase = credentials.sshPassphrase?.isEmpty == true ? nil : credentials.sshPassphrase
                    try library.storeSSHKey(
                        for: server.id,
                        privateKey: sshKey,
                        passphrase: passphrase,
                        publicKey: credentials.publicKey
                    )
                }
            }
        }

        if server.connectionMode == .cloudflare,
           server.cloudflareAccessMode == .serviceToken,
           let cloudflareClientID = credentials.cloudflareClientID,
           let cloudflareClientSecret = credentials.cloudflareClientSecret {
            try library.storeCloudflareServiceToken(
                for: server.id,
                clientID: cloudflareClientID,
                clientSecret: cloudflareClientSecret
            )
        }
    }
}
