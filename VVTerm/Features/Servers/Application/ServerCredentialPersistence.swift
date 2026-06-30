import Foundation

@MainActor
protocol ServerCredentialWritingLibrary: AnyObject {
    func deleteCredentials(for serverId: UUID) throws
    func deletePassword(for serverId: UUID) throws
    func deleteSSHKey(for serverId: UUID) throws
    func deleteCloudflareServiceToken(for serverId: UUID) throws
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
        guard server.connectionMode != .tailscale else {
            try library.deleteCredentials(for: server.id)
            return
        }

        var didStoreAuthCredential = false

        switch server.authMethod {
        case .password:
            if let password = credentials.password, !password.isEmpty {
                try library.storePassword(for: server.id, password: password)
                didStoreAuthCredential = true
            }
        case .sshKey:
            if let sshKey = credentials.sshKey, !sshKey.isEmpty {
                try library.storeSSHKey(
                    for: server.id,
                    privateKey: sshKey,
                    passphrase: nil,
                    publicKey: credentials.publicKey
                )
                didStoreAuthCredential = true
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
                didStoreAuthCredential = true
            }
        }

        if didStoreAuthCredential {
            try deleteSupersededAuthCredentials(for: server)
        }

        let usesCloudflareServiceToken = server.connectionMode == .cloudflare
            && server.cloudflareAccessMode == .serviceToken
        if usesCloudflareServiceToken,
           let cloudflareClientID = credentials.cloudflareClientID,
           let cloudflareClientSecret = credentials.cloudflareClientSecret {
            try library.storeCloudflareServiceToken(
                for: server.id,
                clientID: cloudflareClientID,
                clientSecret: cloudflareClientSecret
            )
        } else if !usesCloudflareServiceToken {
            try library.deleteCloudflareServiceToken(for: server.id)
        }
    }

    private func deleteSupersededAuthCredentials(for server: Server) throws {
        switch server.authMethod {
        case .password:
            try library.deleteSSHKey(for: server.id)
        case .sshKey, .sshKeyWithPassphrase:
            try library.deletePassword(for: server.id)
        }
    }
}
