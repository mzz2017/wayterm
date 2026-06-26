import Foundation

struct ServerFormDraft {
    let workspaceId: UUID
    let environment: ServerEnvironment
    let name: String
    let host: String
    let port: String
    let username: String
    let connectionMode: SSHConnectionMode
    let authMethod: AuthMethod
    let cloudflareAccessMode: CloudflareAccessMode
    let cloudflareTeamDomainOverride: String
    let notes: String
    let requiresBiometricUnlock: Bool
    let multiplexer: TerminalMultiplexer
    let tmuxStartupBehavior: TmuxStartupBehavior
    let password: String
    let sshKey: String
    let sshPassphrase: String
    let sshPublicKey: String
    let cloudflareClientID: String
    let cloudflareClientSecret: String

    var effectiveUsername: String {
        let trimmed = username.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "root" : trimmed
    }
}

struct ServerFormSubmission {
    let server: Server
    let credentials: ServerCredentials
}

struct ServerFormSubmissionBuilder {
    static func build(
        id: UUID,
        createdAt: Date,
        draft: ServerFormDraft
    ) -> ServerFormSubmission {
        let server = Server(
            id: id,
            workspaceId: draft.workspaceId,
            environment: draft.environment,
            name: draft.name,
            host: draft.host,
            port: ServerPortValidator.normalizedPort(from: draft.port) ?? 22,
            username: draft.effectiveUsername,
            connectionMode: draft.connectionMode,
            authMethod: draft.connectionMode == .tailscale ? .password : draft.authMethod,
            cloudflareAccessMode: draft.connectionMode == .cloudflare ? draft.cloudflareAccessMode : nil,
            cloudflareTeamDomainOverride: draft.connectionMode == .cloudflare
                ? normalizedCloudflareOverride(draft.cloudflareTeamDomainOverride)
                : nil,
            cloudflareAppDomainOverride: nil,
            notes: draft.notes.isEmpty ? nil : draft.notes,
            requiresBiometricUnlock: draft.requiresBiometricUnlock,
            multiplexerOverride: draft.multiplexer,
            tmuxStartupBehaviorOverride: draft.tmuxStartupBehavior,
            createdAt: createdAt
        )

        let credentials = ServerFormCredentialBuilder.build(
            serverId: id,
            connectionMode: draft.connectionMode,
            authMethod: draft.authMethod,
            password: draft.password,
            sshKey: draft.sshKey,
            sshPassphrase: draft.sshPassphrase,
            sshPublicKey: draft.sshPublicKey,
            cloudflareAccessMode: draft.connectionMode == .cloudflare ? draft.cloudflareAccessMode : nil,
            cloudflareClientID: draft.cloudflareClientID,
            cloudflareClientSecret: draft.cloudflareClientSecret
        )

        return ServerFormSubmission(server: server, credentials: credentials)
    }

    static func normalizedCloudflareOverride(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct ServerFormDefaults {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func multiplexer() -> TerminalMultiplexer {
        if let raw = defaults.string(forKey: "terminalMultiplexerDefault"),
           let mux = TerminalMultiplexer(rawValue: raw) {
            return mux
        }
        if defaults.object(forKey: "terminalTmuxEnabledDefault") != nil {
            return .fromLegacyTmuxEnabled(defaults.bool(forKey: "terminalTmuxEnabledDefault"))
        }
        return .tmux
    }

    func tmuxStartupBehavior() -> TmuxStartupBehavior {
        guard let rawValue = defaults.string(forKey: "terminalTmuxStartupBehaviorDefault") else {
            return .askEveryTime
        }
        return TmuxStartupBehavior(rawValue: rawValue) ?? .askEveryTime
    }
}
