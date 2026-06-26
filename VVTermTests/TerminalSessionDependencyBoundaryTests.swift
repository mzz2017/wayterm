import Foundation
import Testing

// Test Context:
// These source-boundary tests protect TerminalSessions Application dependency
// ownership. Runtime start and reconnect flows need server metadata, but that
// lookup should route through manager-level dependency providers instead of
// scattering direct Servers feature singleton reads across lifecycle files.
// Update these tests only when the server lookup owner intentionally changes.

struct TerminalSessionDependencyBoundaryTests {
    @Test
    func connectionSessionRuntimeAndReconnectUseInjectedServerProvider() throws {
        let root = try sourceRoot()
        let managerSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/ConnectionSessionManager.swift")
        )
        let runtimeSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/ConnectionSessionManager+Runtime.swift")
        )
        let reconnectSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/ConnectionSessionManager+Reconnect.swift")
        )

        // Given session runtime/reconnect flows need a Server for a session ID.
        #expect(managerSource.contains("typealias ServerProvider"))
        #expect(managerSource.contains("var serverProvider: ServerProvider"))
        #expect(runtimeSource.contains("serverProvider(session.serverId)"))
        #expect(reconnectSource.contains("serverProvider(session.serverId)"))

        // Then those lifecycle files do not reach directly into Servers state.
        #expect(!runtimeSource.contains("ServerManager.shared.servers"))
        #expect(!reconnectSource.contains("ServerManager.shared.servers"))
    }

    @Test
    func terminalTabRuntimeUsesInjectedServerProvider() throws {
        let root = try sourceRoot()
        let managerSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/TerminalTabManager.swift")
        )
        let runtimeSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/TerminalTabManager+Runtime.swift")
        )

        // Given split-pane runtime startup also needs server metadata.
        #expect(managerSource.contains("typealias ServerProvider"))
        #expect(managerSource.contains("var serverProvider: ServerProvider"))
        #expect(runtimeSource.contains("serverProvider(paneState.serverId)"))

        // Then pane runtime startup does not reach directly into Servers state.
        #expect(!runtimeSource.contains("ServerManager.shared.servers"))
    }

    @Test
    func connectionOpenUsesInjectedAccessAndPersistenceBoundaries() throws {
        let root = try sourceRoot()
        let managerSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/ConnectionSessionManager.swift")
        )
        let openSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/ConnectionSessionManager+Open.swift")
        )

        // Given opening a terminal session needs server access policy,
        // app-lock authorization, and last-connected persistence.
        #expect(managerSource.contains("typealias ServerLockPolicy"))
        #expect(managerSource.contains("typealias ServerUnlocker"))
        #expect(managerSource.contains("typealias LastConnectedUpdater"))
        #expect(managerSource.contains("typealias IsProProvider"))
        #expect(openSource.contains("serverLockPolicy(server)"))
        #expect(openSource.contains("await serverUnlocker(server)"))
        #expect(openSource.contains("scheduleLastConnectedUpdate(for: server)"))
        #expect(managerSource.contains("if isProProvider() { return true }"))

        // Then the open lifecycle file does not reach directly into Servers or
        // Security singletons for those cross-feature concerns.
        #expect(!openSource.contains("ServerManager.shared.isServerLocked"))
        #expect(!openSource.contains("AppLockManager.shared.ensureServerUnlocked"))
        #expect(!openSource.contains("ServerManager.shared.updateLastConnected"))
        #expect(!managerSource.contains("if StoreManager.shared.isPro { return true }"))
    }

    @Test
    func terminalTabOpenAndSplitUseInjectedPolicyBoundaries() throws {
        let root = try sourceRoot()
        let managerSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/TerminalTabManager.swift")
        )
        let openSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/TerminalTabManager+Open.swift")
        )

        // Given tab opening needs a default selected view and split/tab limits
        // need entitlement state.
        #expect(managerSource.contains("typealias IsProProvider"))
        #expect(managerSource.contains("typealias DefaultViewProvider"))
        #expect(managerSource.contains("var isProProvider: IsProProvider"))
        #expect(managerSource.contains("var defaultViewProvider: DefaultViewProvider"))
        #expect(openSource.contains("self.defaultViewProvider()"))
        #expect(managerSource.contains("if isProProvider() { return true }"))
        #expect(managerSource.contains("guard isProProvider() else { return nil }"))

        // Then TerminalSessions open/split policy does not reach directly
        // into Store or connection-view configuration singletons.
        #expect(!openSource.contains("ViewTabConfigurationManager.shared"))
        #expect(!managerSource.contains("StoreManager.shared.isPro { return true }"))
        #expect(!managerSource.contains("guard StoreManager.shared.isPro"))
    }

    @Test
    func tmuxResolverUsesInjectedServerProviderBoundary() throws {
        let root = try sourceRoot()
        let resolverSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/TmuxAttachResolver.swift")
        )
        let connectionManagerSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/ConnectionSessionManager.swift")
        )
        let tabManagerSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/TerminalTabManager.swift")
        )
        let connectionTestingSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/ConnectionSessionManager+Testing.swift")
        )
        let tabTestingSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/TerminalTabManager+Testing.swift")
        )

        // Given tmux attach prompts and multiplexer policy need server metadata.
        #expect(resolverSource.contains("typealias ServerProvider"))
        #expect(resolverSource.contains("init(serverProvider: @escaping ServerProvider)"))
        #expect(resolverSource.contains("serverProvider(serverId)"))
        #expect(connectionManagerSource.contains("TmuxAttachResolver(serverProvider:"))
        #expect(tabManagerSource.contains("TmuxAttachResolver(serverProvider:"))
        #expect(connectionTestingSource.contains("tmuxResolver.setServerProvider(provider)"))
        #expect(tabTestingSource.contains("tmuxResolver.setServerProvider(provider)"))

        // Then the resolver does not reach directly into Servers feature state.
        #expect(!resolverSource.contains("ServerManager.shared.servers"))
    }

    private func source(at url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    private func sourceRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.lastPathComponent != "VVTermTests" {
            let next = url.deletingLastPathComponent()
            if next.path == url.path {
                throw SourceRootError.notFound
            }
            url = next
        }
        return url.deletingLastPathComponent()
    }

    private enum SourceRootError: Error {
        case notFound
    }
}
