import Foundation
import Testing
@testable import Waterm

// Test Context:
// These tests protect ServerFormSheet's UI/Application boundary for add/edit
// submission assembly. The UI should collect form fields and send a draft; Servers
// Application owns conversion into Server and ServerCredentials. Update these tests
// only when the submitted server fields, credential rules, or terminal default keys
// intentionally change.
struct ServerFormSubmissionBuilderTests {
    @Test
    func cloudflareServiceTokenSubmissionBuildsServerAndCredentials() {
        let serverId = UUID()
        let workspaceId = UUID()
        let createdAt = Date(timeIntervalSince1970: 1_234)
        let draft = makeDraft(
            workspaceId: workspaceId,
            port: "2200",
            username: "  ",
            connectionMode: .cloudflare,
            authMethod: .password,
            cloudflareAccessMode: .serviceToken,
            cloudflareTeamDomainOverride: "  team.example.com  ",
            notes: "",
            password: "ssh-password",
            cloudflareClientID: "  cf-id  ",
            cloudflareClientSecret: "  cf-secret  "
        )

        // When ServerFormSheet sends a Cloudflare service-token draft.
        let submission = ServerFormSubmissionBuilder.build(
            id: serverId,
            createdAt: createdAt,
            draft: draft
        )

        // Then Application assembly preserves server fields and normalizes boundary-specific values.
        #expect(submission.server.id == serverId)
        #expect(submission.server.workspaceId == workspaceId)
        #expect(submission.server.port == 2200)
        #expect(submission.server.username == "root")
        #expect(submission.server.connectionMode == .cloudflare)
        #expect(submission.server.authMethod == .password)
        #expect(submission.server.cloudflareAccessMode == .serviceToken)
        #expect(submission.server.cloudflareTeamDomainOverride == "team.example.com")
        #expect(submission.server.notes == nil)
        #expect(submission.server.createdAt == createdAt)
        #expect(submission.credentials.password == "ssh-password")
        #expect(submission.credentials.cloudflareClientID == "cf-id")
        #expect(submission.credentials.cloudflareClientSecret == "cf-secret")
    }

    @Test
    func tailscaleSubmissionForcesPasswordAuthAndEmptyCredentials() {
        let draft = makeDraft(
            connectionMode: .tailscale,
            authMethod: .sshKeyWithPassphrase,
            password: "secret",
            sshKey: "PRIVATE",
            sshPassphrase: "phrase",
            sshPublicKey: "PUBLIC"
        )

        // When Tailscale is selected, SSH credential material is not persisted for the temporary connection mode.
        let submission = ServerFormSubmissionBuilder.build(
            id: UUID(),
            createdAt: Date(),
            draft: draft
        )

        // Then the server stays connectable through Tailscale and credentials remain empty.
        #expect(submission.server.connectionMode == .tailscale)
        #expect(submission.server.authMethod == .password)
        #expect(submission.credentials.password == nil)
        #expect(submission.credentials.privateKey == nil)
        #expect(submission.credentials.publicKey == nil)
        #expect(submission.credentials.passphrase == nil)
    }

    @Test
    func defaultsReadModernAndLegacyTerminalSettings() {
        let suiteName = "ServerFormSubmissionBuilderTests.\(#function)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // Given no user setting exists.
        var formDefaults = ServerFormDefaults(defaults: defaults)
        #expect(formDefaults.multiplexer() == .tmux)
        #expect(formDefaults.tmuxStartupBehavior() == .askEveryTime)

        // When modern defaults are present.
        defaults.set(TerminalMultiplexer.zmx.rawValue, forKey: "terminalMultiplexerDefault")
        defaults.set(TmuxStartupBehavior.skipTmux.rawValue, forKey: "terminalTmuxStartupBehaviorDefault")
        formDefaults = ServerFormDefaults(defaults: defaults)

        // Then the form uses the modern terminal defaults.
        #expect(formDefaults.multiplexer() == .zmx)
        #expect(formDefaults.tmuxStartupBehavior() == .skipTmux)

        // When only the legacy tmux boolean remains.
        defaults.removeObject(forKey: "terminalMultiplexerDefault")
        defaults.set(false, forKey: "terminalTmuxEnabledDefault")
        formDefaults = ServerFormDefaults(defaults: defaults)

        // Then the legacy setting still maps to the current multiplexer model.
        #expect(formDefaults.multiplexer() == .none)
    }

    private func makeDraft(
        workspaceId: UUID = UUID(),
        environment: ServerEnvironment = .production,
        name: String = "Production",
        host: String = "example.com",
        port: String = "22",
        username: String = "deploy",
        connectionMode: SSHConnectionMode = .standard,
        authMethod: AuthMethod = .password,
        cloudflareAccessMode: CloudflareAccessMode = .oauth,
        cloudflareTeamDomainOverride: String = "",
        notes: String = "notes",
        requiresBiometricUnlock: Bool = false,
        multiplexer: TerminalMultiplexer = .tmux,
        tmuxStartupBehavior: TmuxStartupBehavior = .askEveryTime,
        password: String = "secret",
        sshKey: String = "",
        sshPassphrase: String = "",
        sshPublicKey: String = "",
        cloudflareClientID: String = "",
        cloudflareClientSecret: String = ""
    ) -> ServerFormDraft {
        ServerFormDraft(
            workspaceId: workspaceId,
            environment: environment,
            name: name,
            host: host,
            port: port,
            username: username,
            connectionMode: connectionMode,
            authMethod: authMethod,
            cloudflareAccessMode: cloudflareAccessMode,
            cloudflareTeamDomainOverride: cloudflareTeamDomainOverride,
            notes: notes,
            requiresBiometricUnlock: requiresBiometricUnlock,
            multiplexer: multiplexer,
            tmuxStartupBehavior: tmuxStartupBehavior,
            password: password,
            sshKey: sshKey,
            sshPassphrase: sshPassphrase,
            sshPublicKey: sshPublicKey,
            cloudflareClientID: cloudflareClientID,
            cloudflareClientSecret: cloudflareClientSecret
        )
    }
}
