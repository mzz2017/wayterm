import Foundation
import Testing
@testable import VVTerm

// Test Context:
// These tests protect the server form's connection-test policy. The UI should
// send a test intent, compare the resulting snapshot to the current draft, and
// display policy-owned failure guidance without owning SSH/Tailscale/Cloudflare
// error interpretation. Update these expectations only when connection-test
// validity or user-facing failure guidance intentionally changes.
struct ServerFormConnectionTestPolicyTests {
    @Test
    func snapshotUsesEffectiveUsernameAndConnectionRelevantDraftFields() {
        // Given a draft whose display username is blank but connection testing uses root.
        let draft = makeDraft(
            username: "  ",
            connectionMode: .cloudflare,
            authMethod: .sshKeyWithPassphrase,
            cloudflareAccessMode: .serviceToken,
            cloudflareTeamDomainOverride: "team.example.com",
            password: "password",
            sshKey: "PRIVATE",
            sshPassphrase: "phrase",
            sshPublicKey: "PUBLIC",
            cloudflareClientID: "client-id",
            cloudflareClientSecret: "client-secret"
        )

        // When the connection-test snapshot is captured.
        let snapshot = ServerFormConnectionTestSnapshot(draft: draft)

        // Then snapshot equality tracks the values that affect the test server and credentials.
        #expect(snapshot.username == "root")
        #expect(snapshot.connectionMode == .cloudflare)
        #expect(snapshot.authMethod == .sshKeyWithPassphrase)
        #expect(snapshot.cloudflareAccessMode == .serviceToken)
        #expect(snapshot.cloudflareTeamDomainOverride == "team.example.com")
        #expect(snapshot.sshKey == "PRIVATE")
        #expect(snapshot.cloudflareClientID == "client-id")
    }

    @Test
    func validConnectionTestRequiresSuccessAndMatchingSnapshot() {
        // Given a successful test for the current draft.
        let snapshot = ServerFormConnectionTestSnapshot(draft: makeDraft(host: "example.com"))

        // Then the test remains valid only while the draft snapshot matches.
        #expect(ServerFormConnectionTestPolicy.hasValidConnectionTest(
            didSucceed: true,
            lastSnapshot: snapshot,
            currentSnapshot: snapshot
        ))

        let changedSnapshot = ServerFormConnectionTestSnapshot(draft: makeDraft(host: "other.example.com"))
        #expect(!ServerFormConnectionTestPolicy.hasValidConnectionTest(
            didSucceed: true,
            lastSnapshot: snapshot,
            currentSnapshot: changedSnapshot
        ))
        #expect(!ServerFormConnectionTestPolicy.hasValidConnectionTest(
            didSucceed: false,
            lastSnapshot: snapshot,
            currentSnapshot: snapshot
        ))
    }

    @Test
    func tailscaleFailureAppendsDirectConnectionReminderOnce() {
        // Given a Tailscale connection test failure without the direct-connection reminder.
        let server = makeServer(connectionMode: .tailscale)
        let failure = ServerFormConnectionTestPolicy.failure(
            from: SSHError.connectionFailed("route unavailable"),
            testServer: server
        )

        // Then the policy appends the current product limitation.
        #expect(failure.message.contains("route unavailable"))
        #expect(failure.message.contains(ServerFormConnectionTestPolicy.tailscaleDirectConnectionReminder))

        // And an SSH error that already includes the reminder is not duplicated.
        let alreadyExplained = ServerFormConnectionTestPolicy.failure(
            from: SSHError.tailscaleAuthenticationNotAccepted,
            testServer: server
        )
        let occurrences = alreadyExplained.message.components(
            separatedBy: ServerFormConnectionTestPolicy.tailscaleDirectConnectionReminder
        ).count - 1
        #expect(occurrences == 1)
    }

    @Test
    func cloudflareConfigurationFailureRequestsOverrideFields() {
        // Given Cloudflare configuration failed during connection testing.
        let failure = ServerFormConnectionTestPolicy.failure(
            from: SSHError.cloudflareConfigurationRequired("missing team domain"),
            testServer: makeServer(connectionMode: .cloudflare)
        )

        // Then the UI can reveal advanced override fields without interpreting SSHError.
        #expect(failure.shouldShowCloudflareOverrides)
        #expect(failure.message.contains("missing team domain"))
    }

    private func makeServer(connectionMode: SSHConnectionMode) -> Server {
        Server(
            workspaceId: UUID(),
            name: "Production",
            host: "example.com",
            username: "deploy",
            connectionMode: connectionMode,
            authMethod: .password
        )
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
