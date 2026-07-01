import Foundation
import Testing

// Test Context:
// These source-boundary tests protect TerminalSessions Application dependency
// ownership. Runtime start, reconnect, host trust, tmux attach, entitlement,
// credential, access, and persistence flows should route through manager-level
// dependency providers instead of scattering direct cross-feature singleton
// reads across lifecycle files. Update these tests only when the relevant
// AGENTS.md architecture boundary intentionally changes.

struct TerminalSessionDependencyBoundaryTests {
    @Test
    func terminalSessionApplicationManagersDoNotImportPlatformUIFrameworks() throws {
        let root = try sourceRoot()
        let managerSources = try [
            "Waterm/Features/TerminalSessions/Application/ConnectionSessionManager.swift",
            "Waterm/Features/TerminalSessions/Application/ConnectionSessionManager+Closing.swift",
            "Waterm/Features/TerminalSessions/Application/TerminalTabManager.swift"
        ].map { path in
            try source(at: root.appendingPathComponent(path))
        }.joined(separator: "\n")
        let surfacePlatformSource = try source(
            at: root.appendingPathComponent("Waterm/Features/TerminalSessions/UI/Terminal/TerminalSurfacePlatformBehavior.swift")
        )

        // Given TerminalSessions Application managers should stay presentation-agnostic.
        #expect(
            !managerSources.contains("import AppKit"),
            "TerminalSessions application managers should not import AppKit; platform focus/window details belong behind surfaces or app/UI boundaries."
        )
        #expect(
            !managerSources.contains("import UIKit"),
            "TerminalSessions application managers should not import UIKit; application active state and keyboard focus should stay injected."
        )
        #expect(
            !managerSources.contains("import SwiftUI"),
            "TerminalSessions application managers should use Combine observation without importing SwiftUI presentation APIs."
        )

        // Then platform window/focus handling stays at the terminal surface UI boundary.
        #expect(surfacePlatformSource.contains("extension GhosttyTerminalView"))
        #expect(surfacePlatformSource.contains("import AppKit"))
        #expect(surfacePlatformSource.contains("import UIKit"))
        #expect(managerSources.contains("requestInitialTerminalSurfaceFocus"))
    }

    @Test
    func connectionSessionRuntimeAndReconnectUseInjectedServerProvider() throws {
        let root = try sourceRoot()
        let managerSource = try source(
            at: root.appendingPathComponent("Waterm/Features/TerminalSessions/Application/ConnectionSessionManager.swift")
        )
        let runtimeSource = try source(
            at: root.appendingPathComponent("Waterm/Features/TerminalSessions/Application/ConnectionSessionManager+Runtime.swift")
        )
        let reconnectSource = try source(
            at: root.appendingPathComponent("Waterm/Features/TerminalSessions/Application/ConnectionSessionManager+Reconnect.swift")
        )

        // Given session runtime/reconnect flows need a Server for a session ID.
        #expect(managerSource.contains("typealias ServerProvider"))
        #expect(managerSource.contains("typealias CredentialsProvider"))
        #expect(managerSource.contains("struct Dependencies"))
        #expect(managerSource.contains("var serverProvider: ServerProvider"))
        #expect(runtimeSource.contains("serverProvider(session.serverId)"))
        #expect(runtimeSource.contains("try await credentialsProvider(server)"))
        #expect(reconnectSource.contains("serverProvider(session.serverId)"))

        // Then those lifecycle files do not reach directly into Servers state.
        #expect(!runtimeSource.contains("ServerManager.shared.servers"))
        #expect(!runtimeSource.contains("KeychainManager.shared.getCredentials"))
        #expect(!reconnectSource.contains("ServerManager.shared.servers"))
    }

    @Test
    func terminalTabRuntimeUsesInjectedServerProvider() throws {
        let root = try sourceRoot()
        let managerSource = try source(
            at: root.appendingPathComponent("Waterm/Features/TerminalSessions/Application/TerminalTabManager.swift")
        )
        let runtimeSource = try source(
            at: root.appendingPathComponent("Waterm/Features/TerminalSessions/Application/TerminalTabManager+Runtime.swift")
        )

        // Given split-pane runtime startup also needs server metadata.
        #expect(managerSource.contains("typealias ServerProvider"))
        #expect(managerSource.contains("typealias CredentialsProvider"))
        #expect(managerSource.contains("struct Dependencies"))
        #expect(managerSource.contains("var serverProvider: ServerProvider"))
        #expect(runtimeSource.contains("serverProvider(paneState.serverId)"))
        #expect(runtimeSource.contains("try await credentialsProvider(server)"))

        // Then pane runtime startup does not reach directly into Servers state.
        #expect(!runtimeSource.contains("ServerManager.shared.servers"))
        #expect(!runtimeSource.contains("KeychainManager.shared.getCredentials"))
    }

    @Test
    func connectionOpenUsesInjectedAccessAndPersistenceBoundaries() throws {
        let root = try sourceRoot()
        let managerSource = try source(
            at: root.appendingPathComponent("Waterm/Features/TerminalSessions/Application/ConnectionSessionManager.swift")
        )
        let liveDependencySource = try source(
            at: root.appendingPathComponent("Waterm/App/TerminalSessionLiveDependencies.swift")
        )
        let openSource = try source(
            at: root.appendingPathComponent("Waterm/Features/TerminalSessions/Application/ConnectionSessionManager+Open.swift")
        )

        // Given opening a terminal session needs server access policy,
        // app-lock authorization, and last-connected persistence.
        #expect(managerSource.contains("typealias ServerLockPolicy"))
        #expect(managerSource.contains("typealias ServerUnlocker"))
        #expect(managerSource.contains("typealias LastConnectedUpdater"))
        #expect(managerSource.contains("typealias IsProProvider"))
        #expect(managerSource.contains("let dependencies = Dependencies.live"))
        #expect(liveDependencySource.contains("extension ConnectionSessionManager.Dependencies"))
        #expect(liveDependencySource.contains("static var live: Self"))
        #expect(openSource.contains("serverLockPolicy(server)"))
        #expect(openSource.contains("await serverUnlocker(server)"))
        #expect(openSource.contains("scheduleLastConnectedUpdate(for: server)"))
        #expect(managerSource.contains("if isProProvider() { return true }"))

        // Then the open lifecycle and manager files do not reach directly into
        // Servers or Security singletons for those cross-feature concerns.
        #expect(!managerSource.contains("ServerManager.shared"))
        #expect(!managerSource.contains("AppLockManager.shared"))
        #expect(!managerSource.contains("KeychainManager.shared"))
        #expect(!managerSource.contains("StoreManager.shared"))
        #expect(!openSource.contains("ServerManager.shared.isServerLocked"))
        #expect(!openSource.contains("AppLockManager.shared.ensureServerUnlocked"))
        #expect(!openSource.contains("ServerManager.shared.updateLastConnected"))
        #expect(!managerSource.contains("if StoreManager.shared.isPro { return true }"))

        // And the live app adapters stay isolated in the App composition
        // layer instead of the TerminalSessions feature.
        #expect(liveDependencySource.contains("ServerManager.shared.servers"))
        #expect(liveDependencySource.contains("ServerManager.shared.isServerLocked"))
        #expect(liveDependencySource.contains("AppLockManager.shared.ensureServerUnlocked"))
        #expect(liveDependencySource.contains("ServerManager.shared.updateLastConnected"))
        #expect(liveDependencySource.contains("KeychainManager.shared.getCredentials"))
    }

    @Test
    func terminalTabOpenAndSplitUseInjectedPolicyBoundaries() throws {
        let root = try sourceRoot()
        let managerSource = try source(
            at: root.appendingPathComponent("Waterm/Features/TerminalSessions/Application/TerminalTabManager.swift")
        )
        let liveDependencySource = try source(
            at: root.appendingPathComponent("Waterm/App/TerminalSessionLiveDependencies.swift")
        )
        let openSource = try source(
            at: root.appendingPathComponent("Waterm/Features/TerminalSessions/Application/TerminalTabManager+Open.swift")
        )

        // Given tab opening needs a default selected view and split/tab limits
        // need entitlement state.
        #expect(managerSource.contains("typealias IsProProvider"))
        #expect(managerSource.contains("typealias DefaultViewProvider"))
        #expect(managerSource.contains("struct Dependencies"))
        #expect(managerSource.contains("var isProProvider: IsProProvider"))
        #expect(managerSource.contains("var defaultViewProvider: DefaultViewProvider"))
        #expect(managerSource.contains("let dependencies = Dependencies.live"))
        #expect(liveDependencySource.contains("extension TerminalTabManager.Dependencies"))
        #expect(liveDependencySource.contains("static var live: Self"))
        #expect(openSource.contains("self.defaultViewProvider()"))
        #expect(managerSource.contains("if isProProvider() { return true }"))
        #expect(managerSource.contains("guard isProProvider() else { return nil }"))

        // Then TerminalSessions open/split policy and manager files do not
        // reach directly into Store, Servers, Security, or connection-view
        // configuration singletons.
        #expect(!managerSource.contains("ServerManager.shared"))
        #expect(!managerSource.contains("AppLockManager.shared"))
        #expect(!managerSource.contains("KeychainManager.shared"))
        #expect(!managerSource.contains("StoreManager.shared"))
        #expect(!managerSource.contains("ViewTabConfigurationManager.shared"))
        #expect(!openSource.contains("ViewTabConfigurationManager.shared"))
        #expect(!managerSource.contains("StoreManager.shared.isPro { return true }"))
        #expect(!managerSource.contains("guard StoreManager.shared.isPro"))

        // And the live app adapters stay isolated in the App composition
        // layer instead of the TerminalSessions feature.
        #expect(liveDependencySource.contains("ServerManager.shared.servers"))
        #expect(liveDependencySource.contains("AppLockManager.shared.ensureServerUnlocked"))
        #expect(liveDependencySource.contains("KeychainManager.shared.getCredentials"))
        #expect(liveDependencySource.contains("ViewTabConfigurationManager.shared.effectiveDefaultTab"))
    }

    @Test
    func hostRetrustUsesInjectedKnownHostBoundary() throws {
        let root = try sourceRoot()
        let connectionManagerSource = try source(
            at: root.appendingPathComponent("Waterm/Features/TerminalSessions/Application/ConnectionSessionManager.swift")
        )
        let tabManagerSource = try source(
            at: root.appendingPathComponent("Waterm/Features/TerminalSessions/Application/TerminalTabManager.swift")
        )
        let connectionReconnectSource = try source(
            at: root.appendingPathComponent("Waterm/Features/TerminalSessions/Application/ConnectionSessionManager+Reconnect.swift")
        )
        let tabReconnectSource = try source(
            at: root.appendingPathComponent("Waterm/Features/TerminalSessions/Application/TerminalTabManager+Reconnect.swift")
        )
        let connectionTestingSource = try source(
            at: root.appendingPathComponent("Waterm/Features/TerminalSessions/Application/ConnectionSessionManager+Testing.swift")
        )
        let tabTestingSource = try source(
            at: root.appendingPathComponent("Waterm/Features/TerminalSessions/Application/TerminalTabManager+Testing.swift")
        )
        let liveDependencySource = try source(
            at: root.appendingPathComponent("Waterm/App/TerminalSessionLiveDependencies.swift")
        )
        let reconnectSources = [connectionReconnectSource, tabReconnectSource].joined(separator: "\n")

        // Given changed-host-key recovery must remove the stale trusted host
        // entry before retrying the SSH lifecycle.
        #expect(connectionManagerSource.contains("typealias KnownHostTrustApprover"))
        #expect(tabManagerSource.contains("typealias KnownHostTrustApprover"))
        #expect(connectionManagerSource.contains("knownHostTrustApprover: KnownHostTrustApprover"))
        #expect(tabManagerSource.contains("knownHostTrustApprover: KnownHostTrustApprover"))
        #expect(connectionReconnectSource.contains("await knownHostTrustApprover(server.host, server.port)"))
        #expect(tabReconnectSource.contains("await knownHostTrustApprover(server.host, server.port)"))
        #expect(connectionTestingSource.contains("func setKnownHostTrustApproverForTesting"))
        #expect(tabTestingSource.contains("func setKnownHostTrustApproverForTesting"))

        // Then TerminalSessions does not reach directly into Core's known-hosts
        // actor except through the App-composed live adapter.
        #expect(!reconnectSources.contains("KnownHostsStore.shared"))
        #expect(liveDependencySource.contains("await KnownHostsStore.shared.remove(host: host, port: port)"))
    }

    @Test
    func tmuxResolverUsesInjectedServerProviderAndServiceBoundaries() throws {
        let root = try sourceRoot()
        let resolverSource = try source(
            at: root.appendingPathComponent("Waterm/Features/TerminalSessions/Application/TmuxAttachResolver.swift")
        )
        let connectionManagerSource = try source(
            at: root.appendingPathComponent("Waterm/Features/TerminalSessions/Application/ConnectionSessionManager.swift")
        )
        let tabManagerSource = try source(
            at: root.appendingPathComponent("Waterm/Features/TerminalSessions/Application/TerminalTabManager.swift")
        )
        let connectionTestingSource = try source(
            at: root.appendingPathComponent("Waterm/Features/TerminalSessions/Application/ConnectionSessionManager+Testing.swift")
        )
        let tabTestingSource = try source(
            at: root.appendingPathComponent("Waterm/Features/TerminalSessions/Application/TerminalTabManager+Testing.swift")
        )
        let tmuxServiceSource = try source(
            at: root.appendingPathComponent("Waterm/Features/TerminalSessions/Application/TerminalTmuxService.swift")
        )
        let tmuxPreferenceSource = try source(
            at: root.appendingPathComponent("Waterm/Features/TerminalSessions/Application/TmuxAttachPreferences.swift")
        )
        let tmuxPreferenceInfrastructureSource = try source(
            at: root.appendingPathComponent("Waterm/Features/TerminalSessions/Infrastructure/UserDefaultsTmuxAttachPreferences.swift")
        )
        let liveDependencySource = try source(
            at: root.appendingPathComponent("Waterm/App/TerminalSessionLiveDependencies.swift")
        )
        let tmuxApplicationSources = try [
            "Waterm/Features/TerminalSessions/Application/ConnectionSessionManager+Closing.swift",
            "Waterm/Features/TerminalSessions/Application/ConnectionSessionManager+Open.swift",
            "Waterm/Features/TerminalSessions/Application/ConnectionSessionManager+Tmux.swift",
            "Waterm/Features/TerminalSessions/Application/TerminalTabManager+Closing.swift",
            "Waterm/Features/TerminalSessions/Application/TerminalTabManager+Runtime.swift",
            "Waterm/Features/TerminalSessions/Application/TerminalTabManager+Tmux.swift",
            "Waterm/Features/TerminalSessions/Application/TmuxAttachResolver.swift"
        ].map { path in
            try source(at: root.appendingPathComponent(path))
        }.joined(separator: "\n")

        // Given tmux attach prompts and multiplexer policy need server metadata
        // plus remote tmux transport operations.
        #expect(resolverSource.contains("typealias ServerProvider"))
        #expect(resolverSource.contains("tmuxService: any TerminalTmuxServicing"))
        #expect(resolverSource.contains("preferences: any TmuxAttachPreferenceProviding"))
        #expect(resolverSource.contains("serverProvider(serverId)"))
        #expect(resolverSource.contains("tmuxService.tmuxBackend("))
        #expect(resolverSource.contains("preferences.tmuxStartupBehaviorDefault"))
        #expect(resolverSource.contains("preferences.multiplexerDefault"))
        #expect(resolverSource.contains("tmuxService.cleanupDetachedSessions("))
        #expect(resolverSource.contains("tmuxService.interactiveAttachCommand("))
        #expect(connectionManagerSource.contains("tmuxService: any TerminalTmuxServicing"))
        #expect(tabManagerSource.contains("tmuxService: any TerminalTmuxServicing"))
        #expect(connectionManagerSource.contains("tmuxPreferences: any TmuxAttachPreferenceProviding"))
        #expect(tabManagerSource.contains("tmuxPreferences: any TmuxAttachPreferenceProviding"))
        #expect(connectionManagerSource.contains("tmuxService: dependencies.tmuxService"))
        #expect(tabManagerSource.contains("tmuxService: dependencies.tmuxService"))
        #expect(connectionManagerSource.contains("preferences: dependencies.tmuxPreferences"))
        #expect(tabManagerSource.contains("preferences: dependencies.tmuxPreferences"))
        #expect(connectionManagerSource.contains("tmuxResolver.setServerProvider(dependencies.serverProvider)"))
        #expect(tabManagerSource.contains("tmuxResolver.setServerProvider(dependencies.serverProvider)"))
        #expect(connectionManagerSource.contains("tmuxResolver.setTmuxService(dependencies.tmuxService)"))
        #expect(tabManagerSource.contains("tmuxResolver.setTmuxService(dependencies.tmuxService)"))
        #expect(connectionManagerSource.contains("tmuxResolver.setPreferences(dependencies.tmuxPreferences)"))
        #expect(tabManagerSource.contains("tmuxResolver.setPreferences(dependencies.tmuxPreferences)"))
        #expect(connectionTestingSource.contains("func setTmuxServiceForTesting"))
        #expect(tabTestingSource.contains("func setTmuxServiceForTesting"))
        #expect(connectionTestingSource.contains("func setTmuxPreferencesForTesting"))
        #expect(tabTestingSource.contains("func setTmuxPreferencesForTesting"))
        #expect(connectionTestingSource.contains("restoreLiveDependencies()"))
        #expect(tabTestingSource.contains("restoreLiveDependencies()"))
        #expect(tmuxServiceSource.contains("protocol TerminalTmuxServicing"))
        #expect(tmuxPreferenceSource.contains("protocol TmuxAttachPreferenceProviding"))
        #expect(tmuxPreferenceInfrastructureSource.contains("struct UserDefaultsTmuxAttachPreferences"))
        #expect(tmuxPreferenceInfrastructureSource.contains("UserDefaults"))
        #expect(!tmuxPreferenceSource.contains("UserDefaults"))

        // Then live Core tmux wiring is kept at composition boundaries.
        #expect(!resolverSource.contains("ServerManager.shared.servers"))
        #expect(!resolverSource.contains("RemoteTmuxManager.shared"))
        #expect(!resolverSource.contains("UserDefaults.standard"))
        #expect(!tmuxApplicationSources.contains("RemoteTmuxManager.shared"))
        #expect(liveDependencySource.contains("tmuxService: RemoteTmuxManager.shared"))
        #expect(liveDependencySource.contains("tmuxPreferences: UserDefaultsTmuxAttachPreferences()"))
    }

    @Test
    func moshInstallUsesInjectedServiceBoundary() throws {
        let root = try sourceRoot()
        let connectionManagerSource = try source(
            at: root.appendingPathComponent("Waterm/Features/TerminalSessions/Application/ConnectionSessionManager.swift")
        )
        let tabManagerSource = try source(
            at: root.appendingPathComponent("Waterm/Features/TerminalSessions/Application/TerminalTabManager.swift")
        )
        let connectionTmuxSource = try source(
            at: root.appendingPathComponent("Waterm/Features/TerminalSessions/Application/ConnectionSessionManager+Tmux.swift")
        )
        let tabTmuxSource = try source(
            at: root.appendingPathComponent("Waterm/Features/TerminalSessions/Application/TerminalTabManager+Tmux.swift")
        )
        let connectionTestingSource = try source(
            at: root.appendingPathComponent("Waterm/Features/TerminalSessions/Application/ConnectionSessionManager+Testing.swift")
        )
        let tabTestingSource = try source(
            at: root.appendingPathComponent("Waterm/Features/TerminalSessions/Application/TerminalTabManager+Testing.swift")
        )
        let moshServiceSource = try source(
            at: root.appendingPathComponent("Waterm/Features/TerminalSessions/Application/TerminalMoshService.swift")
        )
        let liveDependencySource = try source(
            at: root.appendingPathComponent("Waterm/App/TerminalSessionLiveDependencies.swift")
        )
        let moshInstallSources = [connectionTmuxSource, tabTmuxSource].joined(separator: "\n")

        #expect(moshServiceSource.contains("protocol TerminalMoshServicing"))
        #expect(connectionManagerSource.contains("moshService: any TerminalMoshServicing"))
        #expect(tabManagerSource.contains("moshService: any TerminalMoshServicing"))
        #expect(connectionManagerSource.contains("get { dependencies.moshService }"))
        #expect(tabManagerSource.contains("get { dependencies.moshService }"))
        #expect(connectionTmuxSource.contains("try await moshService.installMoshServer("))
        #expect(tabTmuxSource.contains("try await moshService.installMoshServer("))
        #expect(connectionTestingSource.contains("func setMoshServiceForTesting"))
        #expect(tabTestingSource.contains("func setMoshServiceForTesting"))

        #expect(!moshInstallSources.contains("RemoteMoshManager.shared"))
        #expect(liveDependencySource.contains("moshService: RemoteMoshManager.shared"))
    }

    @Test
    func terminalCloseAnalyticsUsesInjectedEntitlementBoundary() throws {
        let root = try sourceRoot()
        let connectionManagerSource = try source(
            at: root.appendingPathComponent("Waterm/Features/TerminalSessions/Application/ConnectionSessionManager.swift")
        )
        let tabManagerSource = try source(
            at: root.appendingPathComponent("Waterm/Features/TerminalSessions/Application/TerminalTabManager.swift")
        )
        let connectionClosingSource = try source(
            at: root.appendingPathComponent("Waterm/Features/TerminalSessions/Application/ConnectionSessionManager+Closing.swift")
        )
        let tabClosingSource = try source(
            at: root.appendingPathComponent("Waterm/Features/TerminalSessions/Application/TerminalTabManager+Closing.swift")
        )
        let connectionTestingSource = try source(
            at: root.appendingPathComponent("Waterm/Features/TerminalSessions/Application/ConnectionSessionManager+Testing.swift")
        )
        let tabTestingSource = try source(
            at: root.appendingPathComponent("Waterm/Features/TerminalSessions/Application/TerminalTabManager+Testing.swift")
        )
        let liveDependencySource = try source(
            at: root.appendingPathComponent("Waterm/App/TerminalSessionLiveDependencies.swift")
        )
        let terminalTelemetrySources = [
            connectionManagerSource,
            tabManagerSource,
            connectionClosingSource,
            tabClosingSource,
            connectionTestingSource,
            tabTestingSource
        ].joined(separator: "\n")

        // Given close lifecycle records whether other terminals remain active
        // and whether the user is Pro at the manager boundary.
        #expect(connectionClosingSource.contains("terminalSessionEndRecorder(!activeSessions.isEmpty, isProProvider())"))
        #expect(tabClosingSource.contains("terminalSessionEndRecorder(hasConnectedPanes, isProProvider())"))
        #expect(connectionManagerSource.contains("liveActivityRefresher: LiveActivityRefresher"))
        #expect(connectionManagerSource.contains("successfulConnectionRecorder: SuccessfulConnectionRecorder"))
        #expect(connectionManagerSource.contains("terminalSessionEndRecorder: TerminalSessionEndRecorder"))
        #expect(tabManagerSource.contains("splitPaneCreatedTracker: SplitPaneCreatedTracker"))
        #expect(tabManagerSource.contains("splitPaneCreatedTracker()"))
        #expect(liveDependencySource.contains("LiveActivityManager.shared.refresh"))
        #expect(liveDependencySource.contains("EngagementTracker.shared.recordSuccessfulConnection"))
        #expect(liveDependencySource.contains("EngagementTracker.shared.noteTerminalSessionEnded"))
        #expect(liveDependencySource.contains("AnalyticsTracker.shared.trackSplitPaneCreated"))

        // Then terminal application files do not reach directly into live app
        // telemetry/activity singletons or Store state.
        #expect(!connectionClosingSource.contains("StoreManager.shared.isPro"))
        #expect(!tabClosingSource.contains("StoreManager.shared.isPro"))
        #expect(!terminalTelemetrySources.contains("LiveActivityManager.shared"))
        #expect(!terminalTelemetrySources.contains("EngagementTracker.shared"))
        #expect(!terminalTelemetrySources.contains("AnalyticsTracker.shared"))
    }

    @Test
    func terminalCloseFocusRestoreUsesInjectedApplicationActiveBoundary() throws {
        let root = try sourceRoot()
        let connectionManagerSource = try source(
            at: root.appendingPathComponent("Waterm/Features/TerminalSessions/Application/ConnectionSessionManager.swift")
        )
        let connectionClosingSource = try source(
            at: root.appendingPathComponent("Waterm/Features/TerminalSessions/Application/ConnectionSessionManager+Closing.swift")
        )
        let surfacePlatformSource = try source(
            at: root.appendingPathComponent("Waterm/Features/TerminalSessions/UI/Terminal/TerminalSurfacePlatformBehavior.swift")
        )
        let connectionTestingSource = try source(
            at: root.appendingPathComponent("Waterm/Features/TerminalSessions/Application/ConnectionSessionManager+Testing.swift")
        )
        let liveDependencySource = try source(
            at: root.appendingPathComponent("Waterm/App/TerminalSessionLiveDependencies.swift")
        )

        // Given iOS close UI should only restore keyboard focus while the app
        // is active, but UIKit application state belongs at the app boundary.
        #expect(connectionManagerSource.contains("typealias ApplicationActiveStateProvider"))
        #expect(connectionManagerSource.contains("isApplicationActive: ApplicationActiveStateProvider"))
        #expect(connectionClosingSource.contains("requestInitialTerminalSurfaceFocus(isApplicationActive: self.isApplicationActive())"))
        #expect(surfacePlatformSource.contains("guard isApplicationActive else { return }"))
        #expect(connectionTestingSource.contains("func setApplicationActiveStateProviderForTesting"))
        #expect(liveDependencySource.contains("UIApplication.shared.applicationState == .active"))

        // Then the terminal session application layer no longer reaches
        // directly into UIApplication during close handling.
        #expect(!connectionClosingSource.contains("UIApplication.shared"))
    }

    @Test
    func workingDirectoryRestoreUsesInjectedServiceBoundary() throws {
        let root = try sourceRoot()
        let connectionManagerSource = try source(
            at: root.appendingPathComponent("Waterm/Features/TerminalSessions/Application/ConnectionSessionManager.swift")
        )
        let tabManagerSource = try source(
            at: root.appendingPathComponent("Waterm/Features/TerminalSessions/Application/TerminalTabManager.swift")
        )
        let connectionRuntimeSource = try source(
            at: root.appendingPathComponent("Waterm/Features/TerminalSessions/Application/ConnectionSessionManager+Runtime.swift")
        )
        let tabRuntimeSource = try source(
            at: root.appendingPathComponent("Waterm/Features/TerminalSessions/Application/TerminalTabManager+Runtime.swift")
        )
        let connectionTestingSource = try source(
            at: root.appendingPathComponent("Waterm/Features/TerminalSessions/Application/ConnectionSessionManager+Testing.swift")
        )
        let tabTestingSource = try source(
            at: root.appendingPathComponent("Waterm/Features/TerminalSessions/Application/TerminalTabManager+Testing.swift")
        )
        let serviceSource = try source(
            at: root.appendingPathComponent("Waterm/Features/TerminalSessions/Application/TerminalWorkingDirectoryService.swift")
        )
        let liveDependencySource = try source(
            at: root.appendingPathComponent("Waterm/App/TerminalSessionLiveDependencies.swift")
        )

        // Given working-directory restore runs during shell startup lifecycle.
        #expect(serviceSource.contains("protocol TerminalWorkingDirectoryApplying"))
        #expect(connectionManagerSource.contains("workingDirectoryService: any TerminalWorkingDirectoryApplying"))
        #expect(tabManagerSource.contains("workingDirectoryService: any TerminalWorkingDirectoryApplying"))
        #expect(connectionRuntimeSource.contains("workingDirectoryService.apply"))
        #expect(tabRuntimeSource.contains("workingDirectoryService.apply"))
        #expect(connectionTestingSource.contains("func setWorkingDirectoryServiceForTesting"))
        #expect(tabTestingSource.contains("func setWorkingDirectoryServiceForTesting"))
        #expect(liveDependencySource.contains("workingDirectoryService: TerminalWorkingDirectoryService()"))

        // Then runtime managers do not resolve the live service singleton directly.
        #expect(!connectionRuntimeSource.contains("TerminalWorkingDirectoryService.shared"))
        #expect(!tabRuntimeSource.contains("TerminalWorkingDirectoryService.shared"))
    }

    @Test
    func terminalRuntimePreferencesAreConsumedThroughInjectedApplicationStore() throws {
        let root = try sourceRoot()
        let appSource = try source(
            at: root.appendingPathComponent("Waterm/App/WatermApp.swift")
        )
        let runtimePreferenceSource = try source(
            at: root.appendingPathComponent("Waterm/Features/TerminalSessions/Application/TerminalRuntimePreferencesStore.swift")
        )
        let persistenceSource = try source(
            at: root.appendingPathComponent("Waterm/Features/TerminalSessions/Infrastructure/UserDefaultsTerminalRuntimePreferencesPersistence.swift")
        )
        let uiSources = try [
            "Waterm/Features/TerminalSessions/UI/Terminal/TerminalContainerView.swift",
            "Waterm/Features/TerminalSessions/UI/Terminal/SSHTerminalWrapper.swift",
            "Waterm/Features/TerminalSessions/UI/iOS/iOSTerminalView.swift",
            "Waterm/Features/TerminalSessions/UI/Tabs/ConnectionTabsView.swift",
            "Waterm/Features/TerminalSessions/UI/Splits/TerminalView.swift",
            "Waterm/Features/TerminalSessions/UI/Splits/TerminalPaneView.swift",
            "Waterm/Features/TerminalSessions/UI/Splits/SSHTerminalPaneWrapper.swift",
        ].map { path in
            try source(at: root.appendingPathComponent(path))
        }.joined(separator: "\n")

        // Given terminal UI and surface wrappers need runtime preferences for
        // theme, reconnect, and voice-button decisions.
        #expect(runtimePreferenceSource.contains("final class TerminalRuntimePreferencesStore"))
        #expect(persistenceSource.contains("final class UserDefaultsTerminalRuntimePreferencesPersistence"))
        #expect(appSource.contains("@StateObject private var terminalRuntimePreferences"))
        #expect(appSource.contains(".environmentObject(terminalRuntimePreferences)"))
        #expect(appSource.contains(".environmentObject(terminalVoiceInput)"))
        #expect(uiSources.contains("@EnvironmentObject private var terminalPreferences"))
        #expect(uiSources.contains("autoReconnectEnabled: terminalPreferences.autoReconnectEnabled"))

        // Then runtime UI does not independently read persisted settings or
        // resolve voice input lifecycle state from a global singleton.
        #expect(!uiSources.contains("@AppStorage"))
        #expect(!uiSources.contains("UserDefaults.standard"))
        #expect(!uiSources.contains("TerminalVoiceInputStore.shared"))
        #expect(!uiSources.contains("autoReconnectEnabled: true"))
        #expect(!uiSources.contains("object(forKey: \"sshAutoReconnect\")"))
    }

    private func source(at url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    private func sourceRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.lastPathComponent != "WatermTests" {
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
