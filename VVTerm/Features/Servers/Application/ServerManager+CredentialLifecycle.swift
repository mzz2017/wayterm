import Foundation

extension ServerManager {
    static func defaultDeletionTeardown(for server: Server) async {
        await ConnectionSessionManager.shared.disconnectServerAndWait(server.id)
        await TerminalTabManager.shared.disconnectServerAndWait(server.id)
    }

    static func defaultCredentialDeletion(for serverId: UUID) async throws {
        try KeychainManager.shared.deleteCredentials(for: serverId)
    }

    static func defaultCredentialStore(for server: Server, credentials: ServerCredentials) throws {
        if server.connectionMode != .tailscale {
            switch server.authMethod {
            case .password:
                if let password = credentials.password, !password.isEmpty {
                    try KeychainManager.shared.storePassword(for: server.id, password: password)
                }
            case .sshKey:
                if let sshKey = credentials.sshKey, !sshKey.isEmpty {
                    try KeychainManager.shared.storeSSHKey(
                        for: server.id,
                        privateKey: sshKey,
                        passphrase: nil,
                        publicKey: credentials.publicKey
                    )
                }
            case .sshKeyWithPassphrase:
                if let sshKey = credentials.sshKey, !sshKey.isEmpty {
                    let passphrase = credentials.sshPassphrase?.isEmpty == true ? nil : credentials.sshPassphrase
                    try KeychainManager.shared.storeSSHKey(
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
            try KeychainManager.shared.storeCloudflareServiceToken(
                for: server.id,
                clientID: cloudflareClientID,
                clientSecret: cloudflareClientSecret
            )
        } else {
            KeychainManager.shared.deleteCloudflareServiceToken(for: server.id)
        }
    }
}
