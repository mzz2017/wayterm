import Foundation
import Testing
@testable import VVTerm

// Test Context:
// These tests protect TmuxAttachResolver's injected metadata, preference, and
// tmux service boundaries. The resolver owns tmux prompt/session policy state,
// but server lookup, default settings storage, and remote tmux operations belong
// behind explicit services. Fakes use in-memory Server values, isolated
// UserDefaults suites, and a no-op TerminalTmuxServicing implementation; update
// these tests only when tmux server overrides, attach defaults, or remote tmux
// operations intentionally move to a different application-layer owner.
@MainActor
struct TmuxAttachResolverProviderTests {
    @Test
    func serverOverridesComeFromInjectedProvider() {
        let serverId = UUID()
        let server = Server(
            id: serverId,
            workspaceId: UUID(),
            name: "Tmux Host",
            host: "tmux.example.com",
            username: "root",
            multiplexerOverride: .zmx,
            tmuxStartupBehaviorOverride: .skipTmux
        )
        let resolver = TmuxAttachResolver(
            serverProvider: { requestedId in
                requestedId == serverId ? server : nil
            },
            tmuxService: FakeTerminalTmuxService(),
            preferences: FixedTmuxAttachPreferences(
                tmuxStartupBehaviorDefault: .vvtermManaged,
                multiplexerDefault: .tmux
            )
        )

        // Given a server has per-server tmux overrides.
        let multiplexer = resolver.multiplexer(for: serverId)
        let behavior = resolver.tmuxStartupBehavior(for: serverId)

        // Then resolver policy reads those overrides through the injected
        // provider instead of any app-wide server singleton.
        #expect(multiplexer == .zmx)
        #expect(behavior == .skipTmux)
        #expect(resolver.unavailableStatus(for: serverId) == .off)
    }

    @Test
    func updatedProviderReplacesPreviousServerMetadataSource() {
        let serverId = UUID()
        let first = Server(
            id: serverId,
            workspaceId: UUID(),
            name: "First",
            host: "first.example.com",
            username: "root",
            multiplexerOverride: .tmux,
            tmuxStartupBehaviorOverride: .vvtermManaged
        )
        let second = Server(
            id: serverId,
            workspaceId: UUID(),
            name: "Second",
            host: "second.example.com",
            username: "root",
            multiplexerOverride: TerminalMultiplexer.none,
            tmuxStartupBehaviorOverride: .skipTmux
        )
        let resolver = TmuxAttachResolver(
            serverProvider: { requestedId in
                requestedId == serverId ? first : nil
            },
            tmuxService: FakeTerminalTmuxService(),
            preferences: FixedTmuxAttachPreferences()
        )

        // Given tests or app composition replace the manager-level server
        // provider after resolver construction.
        resolver.setServerProvider { requestedId in
            requestedId == serverId ? second : nil
        }

        // Then future policy resolution uses the new provider.
        #expect(resolver.multiplexer(for: serverId) == .none)
        #expect(resolver.tmuxStartupBehavior(for: serverId) == .skipTmux)
    }

    @Test
    func injectedPreferencesProvideDefaultsWhenServerHasNoOverrides() {
        let serverId = UUID()
        let resolver = TmuxAttachResolver(
            serverProvider: { _ in nil },
            tmuxService: FakeTerminalTmuxService(),
            preferences: FixedTmuxAttachPreferences(
                tmuxStartupBehaviorDefault: .skipTmux,
                multiplexerDefault: .zmx
            )
        )

        // Given no server-specific metadata is available.
        // Then resolver policy uses the injected defaults instead of global UserDefaults.
        #expect(resolver.multiplexer(for: serverId) == .zmx)
        #expect(resolver.tmuxStartupBehavior(for: serverId) == .skipTmux)
    }

    @Test
    func userDefaultsPreferencesPreserveLegacyTmuxEnabledMigration() {
        let defaults = makeDefaults()
        defaults.set(false, forKey: "terminalTmuxEnabledDefault")
        let preferences = UserDefaultsTmuxAttachPreferences(defaults: defaults)

        // Given only the legacy tmux-enabled boolean exists.
        // Then the preference service keeps the old disabled default semantics.
        #expect(preferences.multiplexerDefault == .none)
        #expect(preferences.tmuxStartupBehaviorDefault == .askEveryTime)
    }

    private func makeDefaults(testName: String = #function) -> UserDefaults {
        let suiteName = "TmuxAttachResolverProviderTests.\(testName).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

private final class FakeTerminalTmuxService: TerminalTmuxServicing {
    func tmuxBackend(
        using client: SSHClient,
        preferred: TerminalMultiplexer
    ) async -> RemoteTmuxBackend? {
        nil
    }

    func tmuxInstallBackend(
        using executor: any RemoteCommandExecuting,
        preferred: TerminalMultiplexer
    ) async -> RemoteTmuxBackend? {
        nil
    }

    func isTmuxAvailable(
        using executor: any RemoteCommandExecuting,
        preferred: TerminalMultiplexer
    ) async -> Bool {
        false
    }

    func listSessions(
        using executor: any RemoteCommandExecuting,
        backend: RemoteTmuxBackend
    ) async -> [RemoteTmuxSession] {
        []
    }

    func prepareConfig(
        using executor: any RemoteCommandExecuting,
        terminalType: RemoteTerminalType,
        backend: RemoteTmuxBackend
    ) async {}

    func sendScript(_ script: String, using client: SSHClient, shellId: UUID) async {}

    func killSession(
        named sessionName: String,
        using executor: any RemoteCommandExecuting,
        preferred: TerminalMultiplexer
    ) async {}

    func cleanupLegacySessions(using executor: any RemoteCommandExecuting) async {}

    func cleanupDetachedSessions(
        deviceId: String,
        keeping sessionNames: Set<String>,
        using executor: any RemoteCommandExecuting,
        preferred: TerminalMultiplexer
    ) async {}

    func currentPath(sessionName: String, using executor: any RemoteCommandExecuting) async -> String? {
        nil
    }

    func startupAttachCommand(
        sessionName: String,
        workingDirectory: String,
        backend: RemoteTmuxBackend
    ) -> String {
        "attach \(sessionName) \(workingDirectory)"
    }

    func startupAttachExistingCommand(sessionName: String, backend: RemoteTmuxBackend) -> String {
        "attach-existing \(sessionName)"
    }

    func interactiveAttachCommand(
        sessionName: String,
        workingDirectory: String,
        backend: RemoteTmuxBackend
    ) -> String {
        "exec \(sessionName) \(workingDirectory)"
    }

    func interactiveAttachExistingCommand(sessionName: String, backend: RemoteTmuxBackend) -> String {
        "exec-existing \(sessionName)"
    }

    func installAndAttachScript(
        sessionName: String,
        workingDirectory: String,
        terminalType: RemoteTerminalType,
        backend: RemoteTmuxBackend
    ) -> String {
        "install \(sessionName) \(workingDirectory)"
    }
}
