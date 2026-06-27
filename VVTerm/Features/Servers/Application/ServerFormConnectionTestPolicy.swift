import Foundation

struct ServerFormConnectionTestSnapshot: Equatable {
    let host: String
    let port: String
    let username: String
    let connectionMode: SSHConnectionMode
    let authMethod: AuthMethod
    let password: String
    let sshKey: String
    let sshPassphrase: String
    let sshPublicKey: String
    let cloudflareAccessMode: CloudflareAccessMode
    let cloudflareClientID: String
    let cloudflareClientSecret: String
    let cloudflareTeamDomainOverride: String

    init(draft: ServerFormDraft) {
        host = draft.host
        port = draft.port
        username = draft.effectiveUsername
        connectionMode = draft.connectionMode
        authMethod = draft.authMethod
        password = draft.password
        sshKey = draft.sshKey
        sshPassphrase = draft.sshPassphrase
        sshPublicKey = draft.sshPublicKey
        cloudflareAccessMode = draft.cloudflareAccessMode
        cloudflareClientID = draft.cloudflareClientID
        cloudflareClientSecret = draft.cloudflareClientSecret
        cloudflareTeamDomainOverride = draft.cloudflareTeamDomainOverride
    }
}

struct ServerFormConnectionTestFailure: Equatable {
    let message: String
    let shouldShowCloudflareOverrides: Bool
}

enum ServerFormConnectionTestPolicy {
    static let tailscaleDirectConnectionReminder = String(
        localized: "This app currently supports direct tailnet connections only (no userspace proxy fallback)."
    )

    static func hasValidConnectionTest(
        didSucceed: Bool,
        lastSnapshot: ServerFormConnectionTestSnapshot?,
        currentSnapshot: ServerFormConnectionTestSnapshot
    ) -> Bool {
        didSucceed && lastSnapshot == currentSnapshot
    }

    static func failure(
        from error: Error,
        testServer: Server
    ) -> ServerFormConnectionTestFailure {
        let baseMessage = error.localizedDescription
        let message: String
        if testServer.connectionMode == .tailscale,
           !baseMessage.contains(tailscaleDirectConnectionReminder) {
            message = "\(baseMessage)\n\(tailscaleDirectConnectionReminder)"
        } else {
            message = baseMessage
        }

        let shouldShowCloudflareOverrides: Bool
        if let sshError = error as? SSHError,
           case .cloudflareConfigurationRequired = sshError {
            shouldShowCloudflareOverrides = true
        } else {
            shouldShowCloudflareOverrides = false
        }

        return ServerFormConnectionTestFailure(
            message: message,
            shouldShowCloudflareOverrides: shouldShowCloudflareOverrides
        )
    }
}
