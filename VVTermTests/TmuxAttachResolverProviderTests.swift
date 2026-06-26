import Foundation
import Testing
@testable import VVTerm

// Test Context:
// These tests protect TmuxAttachResolver's server metadata boundary. The
// resolver owns tmux prompt/session policy state, but server lookup belongs to
// the terminal session manager boundary and must be injected. Fakes use in-memory
// Server values only; update these tests only when tmux server overrides move to
// a different application-layer dependency.
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
        let resolver = TmuxAttachResolver(serverProvider: { requestedId in
            requestedId == serverId ? server : nil
        })

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
        let resolver = TmuxAttachResolver(serverProvider: { requestedId in
            requestedId == serverId ? first : nil
        })

        // Given tests or app composition replace the manager-level server
        // provider after resolver construction.
        resolver.setServerProvider { requestedId in
            requestedId == serverId ? second : nil
        }

        // Then future policy resolution uses the new provider.
        #expect(resolver.multiplexer(for: serverId) == .none)
        #expect(resolver.tmuxStartupBehavior(for: serverId) == .skipTmux)
    }
}
