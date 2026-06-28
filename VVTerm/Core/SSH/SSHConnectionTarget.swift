import Foundation

nonisolated struct SSHConnectionTarget: Hashable, Sendable {
    var host: String
    var port: Int
    var username: String
    var connectionMode: SSHConnectionMode
    var authMethod: AuthMethod
    var cloudflareAccessMode: CloudflareAccessMode?
    var cloudflareTeamDomainOverride: String?

    init(
        host: String,
        port: Int = 22,
        username: String,
        connectionMode: SSHConnectionMode = .standard,
        authMethod: AuthMethod = .password,
        cloudflareAccessMode: CloudflareAccessMode? = nil,
        cloudflareTeamDomainOverride: String? = nil
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.connectionMode = connectionMode
        self.authMethod = authMethod
        self.cloudflareAccessMode = cloudflareAccessMode
        self.cloudflareTeamDomainOverride = cloudflareTeamDomainOverride
    }

    var connectionKey: String {
        [
            host,
            String(port),
            username,
            connectionMode.rawValue,
            authMethod.rawValue,
            cloudflareAccessMode?.rawValue ?? "none",
            cloudflareTeamDomainOverride ?? ""
        ].joined(separator: ":")
    }
}

nonisolated enum SSHConnectionMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case standard
    case tailscale
    case mosh
    case cloudflare

    var id: String { rawValue }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = (try? container.decode(String.self)) ?? Self.standard.rawValue
        self = Self(rawValue: rawValue) ?? .standard
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

nonisolated enum CloudflareAccessMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case oauth
    case serviceToken

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .oauth:
            return String(localized: "OAuth")
        case .serviceToken:
            return String(localized: "Service Token")
        }
    }
}

nonisolated enum AuthMethod: String, Codable, CaseIterable, Identifiable, Sendable {
    case password
    case sshKey
    case sshKeyWithPassphrase

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .password: return String(localized: "Password")
        case .sshKey: return String(localized: "SSH Key")
        case .sshKeyWithPassphrase: return String(localized: "SSH Key + Passphrase")
        }
    }

    var icon: String {
        switch self {
        case .password: return "key.fill"
        case .sshKey: return "lock.doc.fill"
        case .sshKeyWithPassphrase: return "lock.shield.fill"
        }
    }
}

nonisolated struct ServerCredentials: Sendable {
    let serverId: UUID
    var password: String?
    var privateKey: Data?
    var publicKey: Data?
    var passphrase: String?
    var cloudflareClientID: String?
    var cloudflareClientSecret: String?

    var sshKey: Data? {
        get { privateKey }
        set { privateKey = newValue }
    }

    var sshPassphrase: String? {
        get { passphrase }
        set { passphrase = newValue }
    }
}
