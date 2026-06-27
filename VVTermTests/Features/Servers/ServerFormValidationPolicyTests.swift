import Foundation
import Testing
@testable import VVTerm

// Test Context:
// Server form validation gates save and connection-test affordances before
// persistence, keychain writes, or network connection tests run.
// These tests protect the application-layer invariant that transport-specific
// credential requirements stay outside ServerFormSheet UI code. Update them
// when product validation rules intentionally change, not when view layout
// or field presentation changes.
struct ServerFormValidationPolicyTests {
    @Test
    func validPasswordDraftRequiresIdentityHostPortAndPassword() {
        // Given a standard SSH password draft with all required fields.
        let validDraft = makeDraft()

        // Then it can be saved or connection-tested.
        #expect(ServerFormValidationPolicy.isValid(draft: validDraft))

        // Given missing identity, host, port, or password data.
        // Then validation rejects the draft before side effects can run.
        #expect(!ServerFormValidationPolicy.isValid(draft: makeDraft(name: "")))
        #expect(!ServerFormValidationPolicy.isValid(draft: makeDraft(host: "")))
        #expect(!ServerFormValidationPolicy.isValid(draft: makeDraft(port: "0")))
        #expect(!ServerFormValidationPolicy.isValid(draft: makeDraft(password: "")))
    }

    @Test
    func credentialRequirementsFollowAuthMethod() {
        // Given SSH key authentication.
        // Then a private key is required and a passphrase is not.
        #expect(ServerFormValidationPolicy.hasValidCredentials(draft: makeDraft(
            authMethod: .sshKey,
            password: "",
            sshKey: "PRIVATE"
        )))
        #expect(!ServerFormValidationPolicy.hasValidCredentials(draft: makeDraft(
            authMethod: .sshKey,
            password: "",
            sshKey: ""
        )))

        // Given SSH key with passphrase authentication.
        // Then both private key and passphrase are required.
        #expect(ServerFormValidationPolicy.hasValidCredentials(draft: makeDraft(
            authMethod: .sshKeyWithPassphrase,
            password: "",
            sshKey: "PRIVATE",
            sshPassphrase: "phrase"
        )))
        #expect(!ServerFormValidationPolicy.hasValidCredentials(draft: makeDraft(
            authMethod: .sshKeyWithPassphrase,
            password: "",
            sshKey: "PRIVATE",
            sshPassphrase: ""
        )))
    }

    @Test
    func tailscaleDoesNotRequireStoredCredentials() {
        let draft = makeDraft(
            connectionMode: .tailscale,
            authMethod: .sshKeyWithPassphrase,
            password: "",
            sshKey: "",
            sshPassphrase: ""
        )

        // Given Tailscale SSH uses server-side policy.
        // Then local password and key material are not required by the form.
        #expect(ServerFormValidationPolicy.hasValidCredentials(draft: draft))
        #expect(ServerFormValidationPolicy.isValid(draft: draft))
    }

    @Test
    func cloudflareServiceTokenRequiresNonBlankClientCredentials() {
        let validDraft = makeDraft(
            connectionMode: .cloudflare,
            cloudflareAccessMode: .serviceToken,
            cloudflareClientID: "  client-id  ",
            cloudflareClientSecret: "  client-secret  "
        )

        // Given Cloudflare service-token mode.
        // Then both client credentials must contain non-whitespace content.
        #expect(ServerFormValidationPolicy.hasValidCredentials(draft: validDraft))
        #expect(!ServerFormValidationPolicy.hasValidCredentials(draft: makeDraft(
            connectionMode: .cloudflare,
            cloudflareAccessMode: .serviceToken,
            cloudflareClientID: "  ",
            cloudflareClientSecret: "client-secret"
        )))
        #expect(!ServerFormValidationPolicy.hasValidCredentials(draft: makeDraft(
            connectionMode: .cloudflare,
            cloudflareAccessMode: .serviceToken,
            cloudflareClientID: "client-id",
            cloudflareClientSecret: "\n\t"
        )))
    }

    @Test
    func cloudflareOAuthStillUsesSelectedSSHAuthRequirements() {
        let draft = makeDraft(
            connectionMode: .cloudflare,
            authMethod: .sshKey,
            cloudflareAccessMode: .oauth,
            password: "",
            sshKey: "PRIVATE",
            cloudflareClientID: "",
            cloudflareClientSecret: ""
        )

        // Given Cloudflare OAuth mode.
        // Then Access client credentials are not required, but SSH auth still is.
        #expect(ServerFormValidationPolicy.hasValidCredentials(draft: draft))
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
        notes: String = "",
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
