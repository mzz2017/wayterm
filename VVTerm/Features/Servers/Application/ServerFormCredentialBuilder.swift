import Foundation

struct ServerFormCredentialBuilder {
    static func build(
        serverId: UUID,
        connectionMode: SSHConnectionMode,
        authMethod: AuthMethod,
        password: String,
        sshKey: String,
        sshPassphrase: String,
        sshPublicKey: String,
        cloudflareAccessMode: CloudflareAccessMode?,
        cloudflareClientID: String,
        cloudflareClientSecret: String
    ) -> ServerCredentials {
        var credentials = ServerCredentials(serverId: serverId)

        guard connectionMode != .tailscale else {
            return credentials
        }

        switch authMethod {
        case .password:
            credentials.password = password
        case .sshKey:
            credentials.sshKey = sshKey.data(using: .utf8)
            credentials.publicKey = resolvedPublicKeyData(
                sshPublicKey: sshPublicKey, sshKey: sshKey, passphrase: nil)
        case .sshKeyWithPassphrase:
            credentials.sshKey = sshKey.data(using: .utf8)
            credentials.sshPassphrase = sshPassphrase
            credentials.publicKey = resolvedPublicKeyData(
                sshPublicKey: sshPublicKey, sshKey: sshKey,
                passphrase: sshPassphrase.isEmpty ? nil : sshPassphrase)
        }

        if connectionMode == .cloudflare, cloudflareAccessMode == .serviceToken {
            let clientID = cloudflareClientID.trimmingCharacters(in: .whitespacesAndNewlines)
            let clientSecret = cloudflareClientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
            credentials.cloudflareClientID = clientID.isEmpty ? nil : clientID
            credentials.cloudflareClientSecret = clientSecret.isEmpty ? nil : clientSecret
        }

        return credentials
    }

    /// Use the explicit public key when present; otherwise derive it from the private
    /// key so libssh2 always receives a public key (its nil-derivation is unreliable).
    static func resolvedPublicKeyData(sshPublicKey: String, sshKey: String, passphrase: String?) -> Data? {
        if !sshPublicKey.isEmpty {
            return sshPublicKey.data(using: .utf8)
        }
        guard !sshKey.isEmpty,
              let derived = SSHPublicKeyDeriver.publicKey(fromPrivateKeyPEM: sshKey, passphrase: passphrase) else {
            return nil
        }
        return derived.data(using: .utf8)
    }
}
