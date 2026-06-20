//
//  TerminalTabManager.swift
//  VVTerm
//
//  Manages terminal tabs and their panes.
//  - Tabs are shown in the toolbar
//  - Each tab can have multiple panes via splits
//  - Panes are NOT tabs - they're split views within a tab
//

import Foundation
import SwiftUI
import Combine
import os.log

#if os(macOS)
import AppKit
#endif

@MainActor
final class TerminalTabManager: ObservableObject {
    static let shared = TerminalTabManager()

    private struct PaneCloseResult: Sendable {
        let paneId: UUID
        let tmuxSessionNameToKill: String?
    }

    private struct TabCloseResult: Sendable {
        let serverId: UUID
        let paneCloseResults: [PaneCloseResult]
    }

    private final class PaneRuntimeState {
        let paneId: UUID
        var server: Server
        var credentials: ServerCredentials
        let client: SSHClient
        var shellId: UUID?
        var shellTask: Task<Void, Never>?
        var lastSize: (cols: Int, rows: Int) = (0, 0)
        var onProcessExit: () -> Void

        init(
            paneId: UUID,
            server: Server,
            credentials: ServerCredentials,
            client: SSHClient,
            onProcessExit: @escaping () -> Void
        ) {
            self.paneId = paneId
            self.server = server
            self.credentials = credentials
            self.client = client
            self.onProcessExit = onProcessExit
        }
    }

    // MARK: - Published State

    /// All tabs, organized by server
    @Published var tabsByServer: [UUID: [TerminalTab]] = [:] {
        didSet { schedulePersist() }
    }

    /// Currently selected tab ID per server
    @Published var selectedTabByServer: [UUID: UUID] = [:] {
        didSet {
            schedulePersist()
            updateTmuxSelectionStatuses()
        }
    }

    /// Servers with live terminal transports. Open tabs are tracked by `openServerIds`.
    @Published var connectedServerIds: Set<UUID> = []

    var openServerIds: Set<UUID> {
        Set(tabsByServer.keys)
    }

    var activeServerIds: Set<UUID> {
        terminalConnectionRegistry.activeServerIds
    }

    var hasLivePanes: Bool {
        terminalConnectionRegistry.hasStreamingEntity
    }

    /// Selected view type per server (stats/terminal)
    @Published var selectedViewByServer: [UUID: String] = [:] {
        didSet { schedulePersist() }
    }

    // MARK: - Terminal Registry

    /// Terminal UI surfaces keyed by pane entity. SSH runtime ownership is separate.
    private let terminalSurfaceRegistry = TerminalSurfaceRegistry()
    private var shellRegistry = SSHShellRegistry(staleThreshold: 120)
    /// Server IDs with an in-flight tab-open request to avoid queued duplicates.
    private var tabOpensInFlight: Set<UUID> = []
    /// In-flight SSH teardown tasks by server, used to serialize close/open ordering.
    private var serverTeardownTasks: [UUID: [UUID: Task<Void, Never>]] = [:]
    /// Application-owned pane SSH runtimes. SwiftUI coordinators attach surfaces and send intent only.
    private var paneRuntimes: [UUID: PaneRuntimeState] = [:]
    private let terminalConnectionRegistry = TerminalConnectionRegistry()
    #if DEBUG
    private var testingTerminalConnectionClientFactory: (@MainActor (TerminalEntityID, Server?) -> any TerminalConnectionClient)?
    #endif

    /// Pane state keyed by pane ID
    @Published var paneStates: [UUID: TerminalPaneState] = [:]
    @Published private(set) var runtimeTitleByPane: [UUID: String] = [:]

    @Published var tmuxAttachPrompt: TmuxAttachPrompt?

    let tmuxResolver = TmuxAttachResolver()

    /// Bumps when a terminal view is registered/unregistered so views refresh.
    @Published private(set) var terminalRegistryVersion: Int = 0

    /// Servers that already ran tmux cleanup (per app launch)
    private var tmuxCleanupServers: Set<UUID> = []

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "TerminalTabManager")

    private let persistenceKey = "terminalTabsSnapshot.v1"
    private var persistTask: Task<Void, Never>?
    private var isRestoring = false

    private init() {
        restoreSnapshot()
    }

    private func paneTmuxStatus(for paneId: UUID) -> TmuxStatus? {
        paneStates[paneId]?.tmuxStatus
    }

    private func setPaneTmuxStatus(_ status: TmuxStatus, for paneId: UUID) {
        paneStates[paneId]?.tmuxStatus = status
    }

    private func paneWorkingDirectory(for paneId: UUID) -> String? {
        paneStates[paneId]?.workingDirectory
    }

    private func setPaneWorkingDirectory(_ workingDirectory: String, for paneId: UUID) {
        paneStates[paneId]?.workingDirectory = workingDirectory
    }

    private func setPanePresentationOverrides(_ presentationOverrides: TerminalPresentationOverrides, for paneId: UUID) {
        paneStates[paneId]?.presentationOverrides = presentationOverrides
    }

    private func setPaneTitle(_ title: String, for paneId: UUID) {
        guard runtimeTitleByPane[paneId] != title else { return }

        runtimeTitleByPane[paneId] = title
        logger.info("Runtime pane title changed: \(title, privacy: .public)")
    }

    private func setPaneTransport(
        _ transport: ShellTransport,
        fallbackReason: MoshFallbackReason?,
        for paneId: UUID
    ) {
        paneStates[paneId]?.activeTransport = transport
        paneStates[paneId]?.moshFallbackReason = fallbackReason
    }

    private func handleStaleShellStartContext(
        _ staleContext: SSHShellRegistry.StartContext?,
        logMessage: StaticString,
        paneId: UUID
    ) {
        guard let staleContext else { return }

        logger.warning("\(logMessage) \(paneId.uuidString, privacy: .public)")
        if !shellRegistry.hasClientReferences(staleContext.client) {
            Task.detached(priority: .utility) { [client = staleContext.client] in
                await client.disconnect()
            }
        }
    }

    // MARK: - Tab Management

    /// Get tabs for a server
    func tabs(for serverId: UUID) -> [TerminalTab] {
        tabsByServer[serverId] ?? []
    }

    /// Get currently selected tab for a server
    func selectedTab(for serverId: UUID) -> TerminalTab? {
        guard let tabId = selectedTabByServer[serverId] else {
            return tabs(for: serverId).first
        }
        return tabs(for: serverId).first { $0.id == tabId }
    }

    /// Check if can open new tab (Pro limit check)
    var canOpenNewTab: Bool {
        if StoreManager.shared.isPro { return true }
        let totalTabs = tabsByServer.values.flatMap { $0 }.count
        return totalTabs < FreeTierLimits.maxTabs
    }

    /// Open a new tab for a server
    @discardableResult
    func openTab(for server: Server) async throws -> TerminalTab {
        await waitForServerTeardownTasks(server.id)

        if tabOpensInFlight.contains(server.id) {
            throw VVTermError.connectionFailed(
                String(localized: "A tab is already opening for this server.")
            )
        }
        tabOpensInFlight.insert(server.id)
        defer { tabOpensInFlight.remove(server.id) }

        guard await AppLockManager.shared.ensureServerUnlocked(server) else {
            throw VVTermError.authenticationFailed
        }

        let tab = TerminalTab(serverId: server.id, title: server.name)

        let sourcePaneId = selectedTab(for: server.id)?.focusedPaneId
        let sourceWorkingDirectory = sourcePaneId
            .flatMap { paneStates[$0]?.workingDirectory }

        // Create pane state FIRST (before any @Published updates)
        // This ensures the view has state when it renders
        var rootState = TerminalPaneState(
            paneId: tab.rootPaneId,
            tabId: tab.id,
            serverId: server.id
        )
        rootState.workingDirectory = sourceWorkingDirectory
        rootState.seedPaneId = sourcePaneId
        rootState.tmuxStatus = tmuxResolver.isTmuxEnabled(for: server.id) ? .unknown : .off
        paneStates[tab.rootPaneId] = rootState

        // Now update tabs (triggers @Published, view will have state ready)
        var serverTabs = tabsByServer[server.id] ?? []
        serverTabs.append(tab)
        tabsByServer[server.id] = serverTabs

        // Select the new tab
        selectedTabByServer[server.id] = tab.id

        logger.info("Opened new tab for \(server.name), pane: \(tab.rootPaneId)")
        return tab
    }

    /// Close a tab
    func closeTab(_ tab: TerminalTab) {
        guard let closeResult = closeTabUI(tab) else { return }
        let teardownTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.finishTabClose(closeResult)
        }
        trackServerTeardownTask(teardownTask, for: closeResult.serverId)
    }

    /// Close a tab and wait for every pane's SSH teardown to finish.
    func closeTabAndWait(_ tab: TerminalTab) async {
        await waitForServerTeardownTasks(tab.serverId)
        guard let closeResult = closeTabUI(tab) else { return }
        await finishTabClose(closeResult)
    }

    private func closeTabUI(_ tab: TerminalTab) -> TabCloseResult? {
        guard let currentTab = tabs(for: tab.serverId).first(where: { $0.id == tab.id }) else {
            logger.warning("closeTab: tab not found \(tab.id.uuidString, privacy: .public)")
            return nil
        }

        // Clean up all panes in this tab
        let paneCloseResults = currentTab.allPaneIds.map { preparePaneClose($0) }

        // Remove from tabs
        if var serverTabs = tabsByServer[currentTab.serverId] {
            serverTabs.removeAll { $0.id == currentTab.id }
            tabsByServer[currentTab.serverId] = serverTabs

            // Select another tab if this was selected
            if selectedTabByServer[currentTab.serverId] == currentTab.id {
                selectedTabByServer[currentTab.serverId] = serverTabs.first?.id
            }

            // Keep live transport state separate; explicit disconnect and pane state
            // transitions decide whether a server remains active.
        }

        EngagementTracker.shared.noteTerminalSessionEnded(
            otherTerminalsActive: hasConnectedPanes,
            isPro: StoreManager.shared.isPro
        )

        logger.info("Closed tab \(currentTab.id)")
        return TabCloseResult(
            serverId: currentTab.serverId,
            paneCloseResults: paneCloseResults
        )
    }

    /// Close all tabs for a server
    func closeAllTabs(for serverId: UUID) {
        let serverTabs = tabs(for: serverId)
        for tab in serverTabs {
            closeTab(tab)
        }
    }

    /// Disconnect all tabs for a server and wait for SSH teardown to finish.
    func disconnectServerAndWait(_ serverId: UUID) async {
        await waitForServerTeardownTasks(serverId)
        let closeResults = tabs(for: serverId).compactMap { closeTabUI($0) }
        connectedServerIds.remove(serverId)
        selectedViewByServer.removeValue(forKey: serverId)
        for closeResult in closeResults {
            await finishTabClose(closeResult)
        }
    }

    // MARK: - Split Management

    /// Split a pane horizontally (left | right)
    func splitHorizontal(tab: TerminalTab, paneId: UUID) -> UUID? {
        guard StoreManager.shared.isPro else { return nil }
        let newPaneId = splitPane(tab: tab, paneId: paneId, direction: .horizontal)
        if newPaneId != nil {
            AnalyticsTracker.shared.trackSplitPaneCreated()
        }
        return newPaneId
    }

    /// Split a pane vertically (top / bottom)
    func splitVertical(tab: TerminalTab, paneId: UUID) -> UUID? {
        guard StoreManager.shared.isPro else { return nil }
        let newPaneId = splitPane(tab: tab, paneId: paneId, direction: .vertical)
        if newPaneId != nil {
            AnalyticsTracker.shared.trackSplitPaneCreated()
        }
        return newPaneId
    }

    private func splitPane(tab: TerminalTab, paneId: UUID, direction: TerminalSplitDirection) -> UUID? {
        // Resolve the latest tab from manager state since the passed value can be stale.
        guard let currentTab = tabs(for: tab.serverId).first(where: { $0.id == tab.id }) else {
            logger.warning("splitPane: tab not found \(tab.id.uuidString, privacy: .public)")
            return nil
        }

        let paneExists: Bool
        if let layout = currentTab.layout {
            paneExists = layout.findPane(paneId)
        } else {
            paneExists = currentTab.rootPaneId == paneId
        }
        guard paneExists else {
            logger.warning("splitPane: pane not found \(paneId.uuidString, privacy: .public)")
            return nil
        }

        let newPaneId = UUID()

        // Create pane state FIRST (before any @Published updates)
        // This ensures the view has state when it renders
        var newState = TerminalPaneState(
            paneId: newPaneId,
            tabId: currentTab.id,
            serverId: currentTab.serverId
        )
        newState.workingDirectory = paneStates[paneId]?.workingDirectory
        newState.seedPaneId = paneId
        newState.tmuxStatus = tmuxResolver.isTmuxEnabled(for: currentTab.serverId) ? .unknown : .off
        paneStates[newPaneId] = newState

        // Create the new split node
        let newSplit = TerminalSplitNode.split(TerminalSplitNode.Split(
            direction: direction,
            ratio: 0.5,
            left: .leaf(paneId: paneId),
            right: .leaf(paneId: newPaneId)
        ))

        // Update tab layout
        var updatedTab = currentTab
        if let currentLayout = currentTab.layout {
            updatedTab.layout = currentLayout.replacingPane(paneId, with: newSplit).equalized()
        } else {
            // No layout yet - create one with the split
            updatedTab.layout = newSplit
        }
        updatedTab.focusedPaneId = newPaneId

        // Update tabs array (triggers @Published, view will have state ready)
        updateTab(updatedTab)

        logger.info("Split pane \(paneId) \(direction.rawValue), new pane: \(newPaneId)")
        return newPaneId
    }

    /// Close a pane within a tab
    func closePane(tab: TerminalTab, paneId: UUID) {
        guard let closeResult = closePaneUI(tab: tab, paneId: paneId) else { return }
        let teardownTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.finishTabClose(closeResult)
        }
        trackServerTeardownTask(teardownTask, for: closeResult.serverId)
    }

    /// Close a pane and wait for SSH teardown to finish.
    func closePaneAndWait(_ paneId: UUID) async {
        guard let state = paneStates[paneId],
              let tab = tabs(for: state.serverId).first(where: { $0.id == state.tabId }) else {
            return
        }
        await closePaneAndWait(tab: tab, paneId: paneId)
    }

    /// Close a pane and wait for SSH teardown to finish.
    func closePaneAndWait(tab: TerminalTab, paneId: UUID) async {
        await waitForServerTeardownTasks(tab.serverId)
        guard let closeResult = closePaneUI(tab: tab, paneId: paneId) else { return }
        await finishTabClose(closeResult)
    }

    private func closePaneUI(tab: TerminalTab, paneId: UUID) -> TabCloseResult? {
        // Get current tab from manager (passed tab might be stale)
        guard let currentTab = tabs(for: tab.serverId).first(where: { $0.id == tab.id }) else {
            logger.warning("closePane: tab not found")
            return nil
        }

        let paneExists: Bool
        if let layout = currentTab.layout {
            paneExists = layout.findPane(paneId)
        } else {
            paneExists = currentTab.rootPaneId == paneId
        }
        guard paneExists else {
            logger.warning("closePane: pane not found \(paneId)")
            return nil
        }

        // If this is the only pane, close the tab
        if currentTab.paneCount <= 1 {
            return closeTabUI(currentTab)
        }

        // Update layout FIRST (before cleanup) to avoid "Initializing" flash
        // When cleanupPane triggers @Published, the pane won't be rendered anymore
        var updatedTab = currentTab
        if let currentLayout = currentTab.layout,
           let newLayout = currentLayout.removingPane(paneId) {
            // Always keep the layout - even for single pane
            // This ensures allPaneIds returns the correct remaining pane
            // (not rootPaneId which might have been closed)
            updatedTab.layout = newLayout.equalized()

            // Update focus if needed
            if updatedTab.focusedPaneId == paneId {
                updatedTab.focusedPaneId = newLayout.allPaneIds().first ?? currentTab.rootPaneId
            }
        }
        updateTab(updatedTab)

        // Now clean up the pane (after layout is updated)
        let paneCloseResult = preparePaneClose(paneId)
        logger.info("Closed pane \(paneId)")
        return TabCloseResult(
            serverId: currentTab.serverId,
            paneCloseResults: [paneCloseResult]
        )
    }

    /// Update a tab in the tabs array
    func updateTab(_ tab: TerminalTab) {
        guard var serverTabs = tabsByServer[tab.serverId],
              let index = serverTabs.firstIndex(where: { $0.id == tab.id }) else { return }
        serverTabs[index] = tab
        tabsByServer[tab.serverId] = serverTabs
        updateTmuxFocus(for: tab)
    }

    // MARK: - Terminal Registry

    /// Register a terminal view for a pane
    func registerTerminal(_ terminal: GhosttyTerminalView, for paneId: UUID) {
        terminalSurfaceRegistry.register(terminal, for: .pane(paneId))
        scheduleTerminalRegistryVersionUpdate()
    }

    /// Unregister a terminal view
    func unregisterTerminal(for paneId: UUID) {
        terminalSurfaceRegistry.removeSurface(for: .pane(paneId), cleanup: true)
        scheduleTerminalRegistryVersionUpdate()
    }

    private func scheduleTerminalRegistryVersionUpdate() {
        Task { @MainActor [weak self] in
            self?.terminalRegistryVersion &+= 1
        }
    }

    /// Get terminal for a pane
    func getTerminal(for paneId: UUID) -> GhosttyTerminalView? {
        terminalSurfaceRegistry.surface(for: .pane(paneId))
    }

    func configureRuntime(
        forPane paneId: UUID,
        server: Server,
        credentials: ServerCredentials,
        onProcessExit: @escaping () -> Void
    ) {
        if let runtime = paneRuntimes[paneId] {
            runtime.server = server
            runtime.credentials = credentials
            runtime.onProcessExit = onProcessExit
            return
        }

        paneRuntimes[paneId] = PaneRuntimeState(
            paneId: paneId,
            server: server,
            credentials: credentials,
            client: SSHClient(),
            onProcessExit: onProcessExit
        )
    }

    func attachSurface(_ terminal: GhosttyTerminalView, toPane paneId: UUID) async {
        if terminalSurfaceRegistry.surface(for: .pane(paneId)) !== terminal {
            registerTerminal(terminal, for: paneId)
        }

        startRuntimeIfNeeded(forPane: paneId, terminal: terminal)
    }

    func detachSurface(fromPane paneId: UUID, reason: TerminalSurfaceDetachReason) async {
        switch reason {
        case .viewDisappeared:
            terminalSurfaceRegistry.detachSurface(for: .pane(paneId), cleanup: false)
        case .sessionClosed:
            unregisterTerminal(for: paneId)
        }
    }

    func sendInput(_ data: Data, toPane paneId: UUID) async {
        if let runtime = terminalConnectionRegistry.runtime(for: .pane(paneId)) {
            try? await runtime.send(data)
            return
        }

        guard let runtime = paneRuntimes[paneId] else {
            if let route = registeredShellRoute(forPane: paneId) {
                try? await route.client.write(data, to: route.shellId)
            }
            return
        }

        if let shellId = runtime.shellId {
            do {
                try await runtime.client.write(data, to: shellId)
            } catch {
                logger.error("Failed to send to pane SSH: \(error.localizedDescription)")
            }
            return
        }

        if let route = registeredShellRoute(forPane: paneId) {
            do {
                try await route.client.write(data, to: route.shellId)
            } catch {
                logger.error("Failed to send to pane SSH: \(error.localizedDescription)")
            }
        }
    }

    func resizePane(_ paneId: UUID, cols: Int, rows: Int) async {
        guard cols > 0 && rows > 0 else { return }

        if let runtime = terminalConnectionRegistry.runtime(for: .pane(paneId)) {
            try? await runtime.resize(cols: cols, rows: rows)
            return
        }

        if let runtime = paneRuntimes[paneId] {
            guard cols != runtime.lastSize.cols || rows != runtime.lastSize.rows else { return }
            runtime.lastSize = (cols, rows)

            if let shellId = runtime.shellId {
                do {
                    try await runtime.client.resize(cols: cols, rows: rows, for: shellId)
                } catch {
                    logger.warning("Failed to resize pane PTY: \(error.localizedDescription)")
                }
                return
            }
        }

        guard let route = registeredShellRoute(forPane: paneId) else { return }
        do {
            try await route.client.resize(cols: cols, rows: rows, for: route.shellId)
        } catch {
            logger.warning("Failed to resize pane PTY: \(error.localizedDescription)")
        }
    }

    private func startRuntimeIfNeeded(forPane paneId: UUID, terminal: GhosttyTerminalView) {
        guard let runtime = runtimeStateForStarting(paneId: paneId) else { return }
        startRuntimeIfNeeded(runtime, terminal: terminal)
    }

    private func runtimeStateForStarting(paneId: UUID) -> PaneRuntimeState? {
        if let runtime = paneRuntimes[paneId] {
            return runtime
        }

        guard let paneState = paneStates[paneId],
              let server = ServerManager.shared.servers.first(where: { $0.id == paneState.serverId }) else {
            updatePaneState(paneId, connectionState: .failed("Server not found"))
            return nil
        }

        do {
            let credentials = try KeychainManager.shared.getCredentials(for: server)
            configureRuntime(forPane: paneId, server: server, credentials: credentials, onProcessExit: {})
            return paneRuntimes[paneId]
        } catch {
            updatePaneState(paneId, connectionState: .failed(error.localizedDescription))
            return nil
        }
    }

    private func startRuntimeIfNeeded(_ runtime: PaneRuntimeState, terminal: GhosttyTerminalView) {
        let paneId = runtime.paneId

        if runtime.shellTask != nil {
            logger.debug("Ignoring duplicate start request for pane \(paneId.uuidString, privacy: .public)")
            return
        }

        if let existingShellId = shellId(for: paneId) {
            runtime.shellId = existingShellId
            updatePaneState(paneId, connectionState: .connected)
            logger.debug("Reusing existing shell for pane \(paneId.uuidString, privacy: .public)")
            return
        }

        if runtime.shellId != nil {
            updatePaneState(paneId, connectionState: .connected)
            return
        }

        guard let startResult = beginShellStart(for: paneId, client: runtime.client),
              startResult.started else {
            if shellId(for: paneId) != nil {
                updatePaneState(paneId, connectionState: .connected)
            }
            logger.debug("Shell start already in progress for pane \(paneId.uuidString, privacy: .public)")
            return
        }

        let sshClient = runtime.client
        let server = runtime.server
        let credentials = runtime.credentials
        let onProcessExit = runtime.onProcessExit
        let logger = self.logger
        let shellGeneration = startResult.generation

        runtime.shellTask = Task.detached(priority: .userInitiated) { [weak terminal] in
            defer {
                Task { @MainActor in
                    TerminalTabManager.shared.finishShellStart(
                        for: paneId,
                        client: sshClient,
                        generation: shellGeneration
                    )
                    if TerminalTabManager.shared.paneRuntimes[paneId]?.client === sshClient {
                        TerminalTabManager.shared.paneRuntimes[paneId]?.shellTask = nil
                    }
                }
            }

            guard let terminal else { return }
            await TerminalConnectionRunner.run(
                server: server,
                credentials: credentials,
                sshClient: sshClient,
                terminal: terminal,
                logger: logger,
                onAttempt: { attempt in
                    if attempt == 1 {
                        TerminalTabManager.shared.updatePaneState(paneId, connectionState: .connecting)
                    } else {
                        TerminalTabManager.shared.updatePaneState(paneId, connectionState: .reconnecting(attempt: attempt))
                    }
                },
                startupPlan: {
                    await TerminalTabManager.shared.tmuxStartupPlan(
                        for: paneId,
                        serverId: server.id,
                        client: sshClient
                    )
                },
                registerShell: { shell, skipTmuxLifecycle in
                    TerminalTabManager.shared.registerSSHClient(
                        sshClient,
                        shellId: shell.id,
                        for: paneId,
                        serverId: server.id,
                        transport: shell.transport,
                        fallbackReason: shell.fallbackReason,
                        generation: shellGeneration,
                        skipTmuxLifecycle: skipTmuxLifecycle
                    )
                    TerminalTabManager.shared.paneRuntimes[paneId]?.shellId = shell.id
                    TerminalTabManager.shared.updatePaneState(paneId, connectionState: .connected)
                },
                onBeforeShellStart: { cols, rows in
                    TerminalTabManager.shared.paneRuntimes[paneId]?.lastSize = (cols, rows)
                },
                onShellStarted: { _, shellId in
                    await TerminalTabManager.shared.applyWorkingDirectoryIfNeeded(
                        paneId: paneId,
                        client: sshClient,
                        shellId: shellId
                    )
                },
                onTitleChange: { title in
                    TerminalTabManager.shared.updatePaneTitle(paneId, rawTitle: title)
                },
                shouldContinueStreaming: { data, terminal in
                    guard TerminalTabManager.shared.paneStates[paneId] != nil else { return false }
                    terminal.writeOutput(data)
                    return true
                },
                shouldResetClient: { sshError in
                    switch sshError {
                    case .notConnected, .connectionFailed, .socketError, .timeout, .libssh2:
                        return true
                    case .channelOpenFailed, .shellRequestFailed:
                        let hasOtherRegistrations = await TerminalTabManager.shared.hasOtherRegistrations(
                            using: sshClient,
                            excluding: paneId
                        )
                        return !hasOtherRegistrations
                    case .authenticationFailed, .tailscaleAuthenticationNotAccepted, .cloudflareConfigurationRequired, .cloudflareAuthenticationFailed, .cloudflareTunnelFailed, .hostKeyVerificationFailed, .moshServerMissing, .moshBootstrapFailed, .moshSessionFailed, .unknown:
                        return false
                    }
                },
                onProcessExit: {
                    onProcessExit()
                },
                onFailure: { error, terminal in
                    let errorMsg = "\r\n\u{001B}[31mSSH Error: \(error.localizedDescription)\u{001B}[0m\r\n"
                    if let data = errorMsg.data(using: .utf8) {
                        terminal.writeOutput(data)
                    }
                    TerminalTabManager.shared.updatePaneState(paneId, connectionState: .failed(error.localizedDescription))
                }
            )
        }
    }

    private func registeredShellRoute(forPane paneId: UUID) -> (client: SSHClient, shellId: UUID)? {
        guard let client = getSSHClient(for: paneId),
              let shellId = shellId(for: paneId) else {
            return nil
        }
        return (client: client, shellId: shellId)
    }

    private func cancelRuntime(
        forPane paneId: UUID,
        mode: ShellTeardownMode,
        cleanupTerminal: Bool,
        closeRegisteredShell: Bool
    ) async {
        let runtime = paneRuntimes[paneId]
        runtime?.shellTask?.cancel()
        runtime?.shellTask = nil
        let shellId = runtime?.shellId
        runtime?.shellId = nil

        if cleanupTerminal {
            terminalSurfaceRegistry.removeSurface(for: .pane(paneId), cleanup: true)
        }

        guard let runtime else { return }
        if closeRegisteredShell, let shellId {
            await runtime.client.closeShell(shellId)
        }
        if mode == .fullDisconnect {
            if closeRegisteredShell {
                await runtime.client.disconnect()
            }
            paneRuntimes.removeValue(forKey: paneId)
        }
    }

    private func closeTestingRuntimeIfNeeded(forPane paneId: UUID) async -> Bool {
        guard let runtime = terminalConnectionRegistry.runtime(for: .pane(paneId)) else {
            return false
        }
        await runtime.close(mode: .fullDisconnect)
        return true
    }

    private func applyWorkingDirectoryIfNeeded(
        paneId: UUID,
        client: SSHClient,
        shellId: UUID
    ) async {
        let cwd: String? = await MainActor.run {
            guard TerminalTabManager.shared.shouldApplyWorkingDirectory(for: paneId) else { return nil }
            return TerminalTabManager.shared.workingDirectory(for: paneId)
        }
        guard let cwd else { return }
        let environment = await client.remoteEnvironment()
        guard environment.shellProfile.family != .unknown else { return }
        guard let payload = RemoteTerminalBootstrap.directoryChangeCommand(
            for: cwd,
            environment: environment
        ).data(using: .utf8) else {
            return
        }
        try? await client.write(payload, to: shellId)
    }

    /// Register SSH shell for a pane
    func registerSSHClient(
        _ client: SSHClient,
        shellId: UUID,
        for paneId: UUID,
        serverId: UUID,
        transport: ShellTransport = .ssh,
        fallbackReason: MoshFallbackReason? = nil,
        skipTmuxLifecycle: Bool = false
    ) {
        registerSSHClient(
            client,
            shellId: shellId,
            for: paneId,
            serverId: serverId,
            transport: transport,
            fallbackReason: fallbackReason,
            generation: nil,
            skipTmuxLifecycle: skipTmuxLifecycle
        )
    }

    func registerSSHClient(
        _ client: SSHClient,
        shellId: UUID,
        for paneId: UUID,
        serverId: UUID,
        transport: ShellTransport = .ssh,
        fallbackReason: MoshFallbackReason? = nil,
        generation: SSHShellRegistry.Generation?,
        skipTmuxLifecycle: Bool = false
    ) {
        let registerResult = shellRegistry.register(
            client: client,
            shellId: shellId,
            for: paneId,
            serverId: serverId,
            transport: transport,
            fallbackReason: fallbackReason,
            generation: generation
        )

        if let stale = registerResult.staleIncomingShell {
            logger.warning("Ignoring stale shell registration for pane \(paneId.uuidString, privacy: .public)")
            Task.detached(priority: .utility) { [client = stale.client, shellId = stale.shellId] in
                await client.closeShell(shellId)
                await client.disconnect()
            }
            return
        }

        if let replaced = registerResult.replacedShell {
            Task.detached { [client = replaced.client, shellId = replaced.shellId] in
                await client.closeShell(shellId)
            }
        }

        setPaneTransport(transport, fallbackReason: fallbackReason, for: paneId)

        if !skipTmuxLifecycle {
            Task { [weak self] in
                await self?.handleTmuxLifecycle(paneId: paneId, serverId: serverId, client: client, shellId: shellId)
            }
        }
    }

    /// Unregister SSH shell
    func unregisterSSHClient(for paneId: UUID) async {
        await unregisterSSHClient(for: paneId, killingManagedTmuxSessionNamed: nil)
    }

    private func unregisterSSHClient(
        for paneId: UUID,
        killingManagedTmuxSessionNamed tmuxSessionName: String?
    ) async {
        let unregisterResult = shellRegistry.unregister(for: paneId)

        guard let registration = unregisterResult.registration else {
            if let pendingStart = unregisterResult.pendingStart {
                if !shellRegistry.hasClientReferences(pendingStart.client) {
                    await pendingStart.client.disconnect()
                }
            }
            return
        }

        if let tmuxSessionName {
            await RemoteTmuxManager.shared.killSession(
                named: tmuxSessionName,
                using: registration.client,
                preferred: tmuxResolver.multiplexer(for: registration.serverId)
            )
        }

        await registration.client.closeShell(registration.shellId)

        if !shellRegistry.hasClientReferences(registration.client) {
            await registration.client.disconnect()
        }

        setPaneTransport(.ssh, fallbackReason: nil, for: paneId)
    }

    /// Get SSH client for a pane
    func getSSHClient(for paneId: UUID) -> SSHClient? {
        shellRegistry.client(for: paneId)
    }

    func shellId(for paneId: UUID) -> UUID? {
        shellRegistry.shellId(for: paneId)
    }

    /// Returns true only for the first caller while no live shell exists for the pane.
    func tryBeginShellStart(for paneId: UUID, client: SSHClient) -> Bool {
        beginShellStart(for: paneId, client: client)?.started == true
    }

    func beginShellStart(for paneId: UUID, client: SSHClient) -> SSHShellRegistry.StartResult? {
        guard let serverId = paneStates[paneId]?.serverId else {
            return nil
        }

        let startResult = shellRegistry.tryBeginStart(
            for: paneId,
            serverId: serverId,
            client: client
        )

        handleStaleShellStartContext(
            startResult.staleContext,
            logMessage: "Recovered stale pane shell-start lock for",
            paneId: paneId
        )
        return startResult
    }

    func finishShellStart(for paneId: UUID, client: SSHClient, generation: SSHShellRegistry.Generation? = nil) {
        shellRegistry.finishStart(for: paneId, client: client, generation: generation)
    }

    func isShellStartInFlight(for paneId: UUID) -> Bool {
        let result = shellRegistry.isStartInFlight(for: paneId)
        handleStaleShellStartContext(
            result.staleContext,
            logMessage: "Cleared stale pane shell-start in-flight flag for",
            paneId: paneId
        )
        return result.inFlight
    }

    private func preferredSSHClient(for serverId: UUID, allowPendingStart: Bool) -> SSHClient? {
        if let registration = preferredSSHRegistration(for: serverId) {
            return registration.client
        }

        if allowPendingStart, let client = shellRegistry.firstPendingClient(for: serverId) {
            return client
        }

        return nil
    }

    private func preferredSSHRegistration(for serverId: UUID) -> SSHShellRegistry.Registration? {
        if let selectedTab = selectedTab(for: serverId) {
            let preferredPaneIds = [selectedTab.focusedPaneId, selectedTab.rootPaneId] + selectedTab.allPaneIds
            for paneId in preferredPaneIds {
                if let registration = shellRegistry.registration(for: paneId) {
                    return registration
                }
            }
        }

        let serverTabs = tabs(for: serverId)
        for tab in serverTabs {
            for paneId in tab.allPaneIds {
                if let registration = shellRegistry.registration(for: paneId) {
                    return registration
                }
            }
        }

        return shellRegistry.firstRegistration(for: serverId)
    }

    /// Returns the best-known client for this server, including pending shell starts.
    func sshClient(for serverId: UUID) -> SSHClient? {
        preferredSSHClient(for: serverId, allowPendingStart: true)
    }

    /// Returns only clients that already have a registered shell for this server.
    func activeSSHClient(for serverId: UUID) -> SSHClient? {
        preferredSSHClient(for: serverId, allowPendingStart: false)
    }

    func hasOtherActivePanes(for serverId: UUID, excluding paneId: UUID) -> Bool {
        terminalConnectionRegistry.hasActiveEntity(
            for: serverId,
            excluding: .pane(paneId)
        )
    }

    /// Returns true when the same SSH client instance is registered to another live pane.
    /// This is used to avoid disconnecting a truly shared client during retry cleanup.
    func hasOtherRegistrations(using client: SSHClient, excluding paneId: UUID) -> Bool {
        shellRegistry.hasOtherRegistrations(using: client, excluding: paneId)
    }

    func sharedStatsClient(for serverId: UUID) -> SSHClient? {
        if let livePane = registryLivePaneState(for: serverId) {
            guard let registration = shellRegistry.registration(for: livePane.paneId),
                  registration.transport != .mosh else {
                return nil
            }
            return registration.client
        }

        if let registration = preferredSSHRegistration(for: serverId) {
            guard registration.transport != .mosh else { return nil }
            return registration.client
        }

        return shellRegistry.firstPendingClient(for: serverId)
    }

    private func registryLivePaneState(for serverId: UUID) -> TerminalPaneState? {
        let liveEntityIDs = terminalConnectionRegistry.openingOrStreamingEntityIDs(for: serverId)
        if let selectedTab = selectedTab(for: serverId) {
            let preferredPaneIds = [selectedTab.focusedPaneId, selectedTab.rootPaneId] + selectedTab.allPaneIds
            for paneId in preferredPaneIds where liveEntityIDs.contains(.pane(paneId)) {
                if let state = paneStates[paneId] {
                    return state
                }
            }
        }

        return paneStates.values.first {
            $0.serverId == serverId && liveEntityIDs.contains(.pane($0.paneId))
        }
    }

    /// Remove pane UI/runtime state and return the SSH teardown that must be awaited.
    private func preparePaneClose(_ paneId: UUID) -> PaneCloseResult {
        let tmuxSessionToKill = paneTmuxStatus(for: paneId)
            .flatMap { managedTmuxSessionNameToKill(for: paneId, status: $0) }

        clearTmuxRuntimeState(for: paneId)
        unregisterTerminal(for: paneId)
        paneStates.removeValue(forKey: paneId)
        runtimeTitleByPane.removeValue(forKey: paneId)

        return PaneCloseResult(
            paneId: paneId,
            tmuxSessionNameToKill: tmuxSessionToKill
        )
    }

    private func finishTabClose(_ closeResult: TabCloseResult) async {
        for paneCloseResult in closeResult.paneCloseResults {
            await finishPaneClose(paneCloseResult)
        }
    }

    private func finishPaneClose(_ closeResult: PaneCloseResult) async {
        if await closeTestingRuntimeIfNeeded(forPane: closeResult.paneId) {
            paneRuntimes.removeValue(forKey: closeResult.paneId)
        } else {
            await cancelRuntime(
                forPane: closeResult.paneId,
                mode: .fullDisconnect,
                cleanupTerminal: false,
                closeRegisteredShell: false
            )
        }

        await unregisterSSHClient(
            for: closeResult.paneId,
            killingManagedTmuxSessionNamed: closeResult.tmuxSessionNameToKill
        )
    }

    private func waitForServerTeardownTasks(_ serverId: UUID) async {
        while let tasksById = serverTeardownTasks[serverId], !tasksById.isEmpty {
            for task in tasksById.values {
                await task.value
            }
        }
    }

    private func trackServerTeardownTask(_ task: Task<Void, Never>, for serverId: UUID) {
        let taskId = UUID()
        serverTeardownTasks[serverId, default: [:]][taskId] = task
        logger.info("Tracking tab teardown [serverId: \(serverId.uuidString, privacy: .public), taskId: \(taskId.uuidString, privacy: .public), count: \(self.serverTeardownTasks[serverId]?.count ?? 0)]")

        Task { @MainActor [weak self] in
            await task.value
            guard let self else { return }
            self.serverTeardownTasks[serverId]?.removeValue(forKey: taskId)
            if self.serverTeardownTasks[serverId]?.isEmpty == true {
                self.serverTeardownTasks.removeValue(forKey: serverId)
            }
            self.logger.info("Finished tab teardown [serverId: \(serverId.uuidString, privacy: .public), taskId: \(taskId.uuidString, privacy: .public), remaining: \(self.serverTeardownTasks[serverId]?.count ?? 0)]")
        }
    }

    // MARK: - Pane State

    /// Update connection state for a pane
    func updatePaneState(_ paneId: UUID, connectionState: ConnectionState) {
        paneStates[paneId]?.connectionState = connectionState
        if let serverId = paneStates[paneId]?.serverId {
            terminalConnectionRegistry.updateState(
                TerminalEntityConnectionState(connectionState: connectionState),
                for: .pane(paneId),
                serverId: serverId
            )
            connectedServerIds = activeServerIds
        }
        switch connectionState {
        case .connecting, .reconnecting:
            setPaneTransport(.ssh, fallbackReason: nil, for: paneId)
        case .disconnected, .failed:
            setPanePresentationOverrides(.empty, for: paneId)
            terminalSurfaceRegistry.surface(for: .pane(paneId))?.applyPresentationOverrides(.empty)
            if paneTmuxStatus(for: paneId) == .foreground {
                setPaneTmuxStatus(.background, for: paneId)
            }
        case .connected:
            EngagementTracker.shared.recordSuccessfulConnection(
                id: paneId,
                transport: paneStates[paneId]?.activeTransport.rawValue ?? ShellTransport.ssh.rawValue
            )
        case .idle:
            break
        }
    }

    private var hasConnectedPanes: Bool {
        hasLivePanes
    }

    func updatePaneWorkingDirectory(_ paneId: UUID, rawDirectory: String) {
        guard let normalized = normalizeWorkingDirectory(rawDirectory) else { return }
        setPaneWorkingDirectory(normalized, for: paneId)
    }

    func updatePaneTitle(_ paneId: UUID, rawTitle: String) {
        guard paneStates[paneId] != nil else { return }
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        setPaneTitle(title, for: paneId)
    }

    func presentationOverrides(for paneId: UUID) -> TerminalPresentationOverrides {
        paneStates[paneId]?.presentationOverrides ?? .empty
    }

    func handleTerminalZoom(_ action: TerminalZoomAction, for paneId: UUID) -> TerminalZoomResult? {
        guard paneStates[paneId] != nil else { return nil }

        let currentOverrides = presentationOverrides(for: paneId)
        let overrides = currentOverrides.applyingZoom(action)
        guard overrides != currentOverrides else {
            return TerminalZoomResult(
                presentationOverrides: currentOverrides,
                effectiveFontSize: currentOverrides.resolvedFontSize()
            )
        }
        setPanePresentationOverrides(overrides, for: paneId)
        schedulePersist()
        terminalSurfaceRegistry.surface(for: .pane(paneId))?.applyPresentationOverrides(overrides)
        return TerminalZoomResult(
            presentationOverrides: overrides,
            effectiveFontSize: overrides.resolvedFontSize()
        )
    }

    func displayTitle(for tab: TerminalTab) -> String {
        runtimeTitleByPane[tab.focusedPaneId] ?? runtimeTitleByPane[tab.rootPaneId] ?? tab.title
    }

    func workingDirectory(for paneId: UUID) -> String? {
        paneWorkingDirectory(for: paneId)
    }

    func shouldApplyWorkingDirectory(for paneId: UUID) -> Bool {
        guard let status = paneTmuxStatus(for: paneId) else { return false }
        return status == .off || status == .missing
    }

    func updatePaneTmuxStatus(_ paneId: UUID, status: TmuxStatus) {
        setPaneTmuxStatus(status, for: paneId)
    }

    // MARK: - tmux Integration

    private func setTmuxAttachPrompt(_ prompt: TmuxAttachPrompt?) {
        tmuxAttachPrompt = prompt
    }

    private func clearTmuxRuntimeState(for paneId: UUID) {
        tmuxResolver.clearRuntimeState(for: paneId, setPrompt: setTmuxAttachPrompt)
    }

    func resolveTmuxAttachPrompt(paneId: UUID, selection: TmuxAttachSelection) {
        tmuxResolver.resolvePrompt(entityId: paneId, selection: selection, setPrompt: setTmuxAttachPrompt)
    }

    func cancelTmuxAttachPrompt(paneId: UUID) {
        tmuxResolver.cancelPrompt(entityId: paneId, setPrompt: setTmuxAttachPrompt)
    }

    private func managedTmuxSessionNames(for serverId: UUID) -> Set<String> {
        var names: Set<String> = []
        for tab in tabs(for: serverId) {
            for paneId in tab.allPaneIds {
                let ownership = tmuxResolver.sessionOwnership[paneId] ?? .managed
                guard ownership == .managed else { continue }
                names.insert(tmuxResolver.sessionName(for: paneId))
            }
        }
        return names
    }

    private func tmuxSessionNamesToKeep(
        for serverId: UUID,
        paneId: UUID,
        selection: TmuxAttachSelection
    ) -> Set<String> {
        var names = managedTmuxSessionNames(for: serverId)
        switch selection {
        case .skipTmux:
            break
        case .createManaged:
            names.insert(tmuxResolver.sessionName(for: paneId))
        case .attachExisting(let sessionName):
            names.insert(sessionName)
        }
        return names
    }

    private func currentTmuxStatus(for paneId: UUID, serverId: UUID) -> TmuxStatus {
        guard let tab = selectedTab(for: serverId) else { return .background }
        return (tab.id == selectedTabByServer[serverId] && tab.focusedPaneId == paneId) ? .foreground : .background
    }

    private func disableTmuxAttachment(for paneId: UUID, status: TmuxStatus) {
        tmuxResolver.clearAttachmentState(for: paneId)
        updatePaneTmuxStatus(paneId, status: status)
    }

    private func runTmuxCleanupIfNeeded(
        for serverId: UUID,
        paneId: UUID,
        selection: TmuxAttachSelection,
        using client: SSHClient
    ) async {
        var cleanupSet = tmuxCleanupServers
        await tmuxResolver.runCleanupIfNeeded(
            serverId: serverId,
            cleanupSet: &cleanupSet,
            managedNames: tmuxSessionNamesToKeep(for: serverId, paneId: paneId, selection: selection),
            using: client
        )
        tmuxCleanupServers = cleanupSet
    }

    private func prepareActiveTmuxPane(
        for paneId: UUID,
        serverId: UUID,
        using client: SSHClient,
        backend: RemoteTmuxBackend
    ) async {
        updatePaneTmuxStatus(paneId, status: currentTmuxStatus(for: paneId, serverId: serverId))
        let terminalType = await client.remoteTerminalType()
        await RemoteTmuxManager.shared.prepareConfig(using: client, terminalType: terminalType, backend: backend)
    }

    private func immediateTmuxSelection(for paneId: UUID) -> TmuxAttachSelection {
        if tmuxResolver.sessionOwnership[paneId] == .external {
            return .attachExisting(sessionName: tmuxResolver.sessionName(for: paneId))
        }

        tmuxResolver.sessionNames[paneId] = tmuxResolver.managedSessionName(for: paneId)
        tmuxResolver.sessionOwnership[paneId] = .managed
        return .createManaged
    }

    private func tmuxStartupCommand(
        for paneId: UUID,
        selection: TmuxAttachSelection,
        workingDirectory: String,
        backend: RemoteTmuxBackend
    ) -> String? {
        switch selection {
        case .skipTmux:
            return nil
        case .createManaged:
            return RemoteTmuxManager.shared.attachCommand(
                sessionName: tmuxResolver.sessionName(for: paneId),
                workingDirectory: workingDirectory,
                backend: backend
            )
        case .attachExisting(let sessionName):
            return RemoteTmuxManager.shared.attachExistingCommand(sessionName: sessionName, backend: backend)
        }
    }

    private func resolveTmuxWorkingDirectory(for paneId: UUID, using client: SSHClient) async -> String {
        if let seedPaneId = paneStates[paneId]?.seedPaneId,
           let path = await RemoteTmuxManager.shared.currentPath(
               sessionName: tmuxResolver.sessionName(for: seedPaneId),
               using: client
           ) {
            setPaneWorkingDirectory(path, for: paneId)
            return path
        }

        if let path = await RemoteTmuxManager.shared.currentPath(
            sessionName: tmuxResolver.sessionName(for: paneId),
            using: client
        ) {
            setPaneWorkingDirectory(path, for: paneId)
            return path
        }

        if let candidate = paneWorkingDirectory(for: paneId)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !candidate.isEmpty {
            return candidate
        }

        return "~"
    }

    private func normalizeWorkingDirectory(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let schemeRange = trimmed.range(of: "://") {
            let afterScheme = trimmed[schemeRange.upperBound...]
            guard let pathStart = afterScheme.firstIndex(of: "/") else { return nil }
            let path = String(afterScheme[pathStart...])
            return path.removingPercentEncoding ?? path
        }

        return trimmed
    }

    private func updateTmuxSelectionStatuses() {
        for serverId in tabsByServer.keys {
            let tabsForServer = tabs(for: serverId)
            for tab in tabsForServer {
                updateTmuxFocus(for: tab)
            }
        }
    }

    private func updateTmuxFocus(for tab: TerminalTab) {
        let isSelectedTab = selectedTabByServer[tab.serverId] == tab.id
        for paneId in tab.allPaneIds {
            guard let state = paneStates[paneId] else { continue }
            guard state.tmuxStatus == .foreground || state.tmuxStatus == .background else { continue }
            let newStatus: TmuxStatus = (isSelectedTab && tab.focusedPaneId == paneId) ? .foreground : .background
            if state.tmuxStatus != newStatus {
                setPaneTmuxStatus(newStatus, for: paneId)
            }
        }
    }

    private func handleTmuxLifecycle(
        paneId: UUID,
        serverId: UUID,
        client: SSHClient,
        shellId: UUID
    ) async {
        guard tmuxResolver.isTmuxEnabled(for: serverId) else {
            await MainActor.run {
                self.disableTmuxAttachment(for: paneId, status: .off)
            }
            return
        }

        guard await client.supportsTmuxRuntime() else {
            logger.info("Resolved remote environment does not support tmux runtime for pane \(paneId.uuidString, privacy: .public); using plain SSH shell")
            await MainActor.run {
                self.disableTmuxAttachment(for: paneId, status: .off)
            }
            return
        }

        guard let backend = await RemoteTmuxManager.shared.tmuxBackend(
            using: client,
            preferred: tmuxResolver.multiplexer(for: serverId)
        ) else {
            await MainActor.run {
                self.disableTmuxAttachment(for: paneId, status: self.tmuxResolver.unavailableStatus(for: serverId))
            }
            return
        }

        let selection = immediateTmuxSelection(for: paneId)
        await runTmuxCleanupIfNeeded(for: serverId, paneId: paneId, selection: selection, using: client)
        await prepareActiveTmuxPane(for: paneId, serverId: serverId, using: client, backend: backend)

        let workingDirectory = await resolveTmuxWorkingDirectory(for: paneId, using: client)
        guard let command = tmuxResolver.buildAttachExecCommand(
            for: paneId,
            selection: selection,
            workingDirectory: workingDirectory,
            backend: backend
        ) else {
            return
        }

        await RemoteTmuxManager.shared.sendScript(command, using: client, shellId: shellId)
    }

    func tmuxStartupPlan(
        for paneId: UUID,
        serverId: UUID,
        client: SSHClient
    ) async -> (command: String?, skipTmuxLifecycle: Bool) {
        guard tmuxResolver.isTmuxEnabled(for: serverId) else {
            disableTmuxAttachment(for: paneId, status: .off)
            return (nil, true)
        }

        guard await client.supportsTmuxRuntime() else {
            disableTmuxAttachment(for: paneId, status: .off)
            return (nil, true)
        }

        guard let backend = await RemoteTmuxManager.shared.tmuxBackend(
            using: client,
            preferred: tmuxResolver.multiplexer(for: serverId)
        ) else {
            disableTmuxAttachment(for: paneId, status: tmuxResolver.unavailableStatus(for: serverId))
            return (nil, true)
        }

        let selection = await tmuxResolver.resolveSelection(
            for: paneId, serverId: serverId, client: client, setPrompt: setTmuxAttachPrompt
        )
        tmuxResolver.updateAttachmentState(for: paneId, serverId: serverId, selection: selection, setPrompt: setTmuxAttachPrompt)

        if case .skipTmux = selection {
            updatePaneTmuxStatus(paneId, status: .off)
            return (nil, true)
        }

        await runTmuxCleanupIfNeeded(for: serverId, paneId: paneId, selection: selection, using: client)
        await prepareActiveTmuxPane(for: paneId, serverId: serverId, using: client, backend: backend)

        let workingDirectory = await resolveTmuxWorkingDirectory(for: paneId, using: client)
        return (
            tmuxStartupCommand(
                for: paneId,
                selection: selection,
                workingDirectory: workingDirectory,
                backend: backend
            ),
            true
        )
    }

    func startTmuxInstall(for paneId: UUID) async {
        guard let registration = shellRegistry.registration(for: paneId) else { return }
        let serverId = registration.serverId
        guard tmuxResolver.isTmuxEnabled(for: serverId) else { return }

        updatePaneTmuxStatus(paneId, status: .installing)

        let preferred = tmuxResolver.multiplexer(for: serverId)
        guard let backend = await RemoteTmuxManager.shared.tmuxInstallBackend(using: registration.client, preferred: preferred) else {
            updatePaneTmuxStatus(paneId, status: .off)
            return
        }

        let sessionName = tmuxResolver.sessionName(for: paneId)
        let workingDirectory = await resolveTmuxWorkingDirectory(for: paneId, using: registration.client)
        let terminalType = await registration.client.remoteTerminalType()
        let script = RemoteTmuxManager.shared.installAndAttachScript(
            sessionName: sessionName,
            workingDirectory: workingDirectory,
            terminalType: terminalType,
            backend: backend
        )
        await RemoteTmuxManager.shared.sendScript(script, using: registration.client, shellId: registration.shellId)

        Task { [weak self] in
            guard let self else { return }
            for _ in 0..<6 {
                try? await Task.sleep(for: .seconds(2))
                let available = await RemoteTmuxManager.shared.isTmuxAvailable(using: registration.client, preferred: preferred)
                if available {
                    await MainActor.run {
                        self.tmuxResolver.bindManagedSession(for: paneId, serverId: serverId)
                        self.updatePaneTmuxStatus(paneId, status: self.currentTmuxStatus(for: paneId, serverId: serverId))
                    }
                    return
                }
            }
            await MainActor.run {
                self.updatePaneTmuxStatus(paneId, status: self.tmuxResolver.unavailableStatus(for: serverId))
            }
        }
    }

    func installMoshServer(for paneId: UUID) async throws {
        guard let registration = shellRegistry.registration(for: paneId) else {
            throw SSHError.notConnected
        }
        try await RemoteMoshManager.shared.installMoshServer(using: registration.client)
    }

    private func managedTmuxSessionNameToKill(for paneId: UUID, status: TmuxStatus) -> String? {
        guard status == .foreground || status == .background || status == .installing else { return nil }
        let ownership = tmuxResolver.sessionOwnership[paneId] ?? .managed
        guard ownership == .managed else { return nil }
        return tmuxResolver.sessionName(for: paneId)
    }

    func killTmuxIfNeeded(for paneId: UUID) {
        guard let registration = shellRegistry.registration(for: paneId) else { return }
        let ownership = tmuxResolver.sessionOwnership[paneId] ?? .managed
        guard ownership == .managed else { return }

        let sessionName = tmuxResolver.sessionName(for: paneId)
        let preferred = tmuxResolver.multiplexer(for: registration.serverId)
        Task.detached { [client = registration.client, sessionName, preferred] in
            await RemoteTmuxManager.shared.killSession(named: sessionName, using: client, preferred: preferred)
        }
    }

    func disableTmux(for serverId: UUID) {
        for (paneId, state) in paneStates where state.serverId == serverId {
            setPaneTmuxStatus(.off, for: paneId)
            clearTmuxRuntimeState(for: paneId)
        }
    }

    // MARK: - Persistence

    private func makeServerSnapshots() -> [TerminalTabsSnapshot.ServerSnapshot] {
        tabsByServer.map { serverId, tabs in
            TerminalTabsSnapshot.ServerSnapshot(
                serverId: serverId,
                tabs: tabs.map { TerminalTabsSnapshot.TabSnapshot(from: $0, paneStates: paneStates) },
                selectedTabId: selectedTabByServer[serverId],
                selectedView: selectedViewByServer[serverId]
            )
        }
    }

    private func makeSnapshot() -> TerminalTabsSnapshot {
        TerminalTabsSnapshot(servers: makeServerSnapshots())
    }

    private func makeRestoredPaneStates(
        from tabsByServer: [UUID: [TerminalTab]],
        snapshotsByTabId: [UUID: TerminalTabsSnapshot.TabSnapshot]
    ) -> [UUID: TerminalPaneState] {
        var restoredPaneStates: [UUID: TerminalPaneState] = [:]

        for tabs in tabsByServer.values {
            for tab in tabs {
                for paneId in tab.allPaneIds {
                    var paneState = TerminalPaneState(
                        paneId: paneId,
                        tabId: tab.id,
                        serverId: tab.serverId
                    )
                    if !tmuxResolver.isTmuxEnabled(for: tab.serverId) {
                        paneState.tmuxStatus = .off
                    }
                    paneState.presentationOverrides = snapshotsByTabId[tab.id]?.panePresentationOverrides?[paneId] ?? .empty
                    restoredPaneStates[paneId] = paneState
                }
            }
        }

        return restoredPaneStates
    }

    private func applyRestoredSnapshot(_ snapshot: TerminalTabsSnapshot) {
        var restoredTabsByServer: [UUID: [TerminalTab]] = [:]
        var restoredSelectedTabs: [UUID: UUID] = [:]
        var restoredSelectedViews: [UUID: String] = [:]
        var snapshotsByTabId: [UUID: TerminalTabsSnapshot.TabSnapshot] = [:]

        for server in snapshot.servers {
            for tabSnapshot in server.tabs {
                snapshotsByTabId[tabSnapshot.id] = tabSnapshot
            }
            let tabs = server.tabs.map { $0.toTerminalTab() }
            restoredTabsByServer[server.serverId] = tabs
            if let selected = server.selectedTabId {
                restoredSelectedTabs[server.serverId] = selected
            }
            if let view = server.selectedView {
                restoredSelectedViews[server.serverId] = view
            }
        }

        tabsByServer = restoredTabsByServer
        selectedTabByServer = restoredSelectedTabs
        selectedViewByServer = restoredSelectedViews
        paneStates = makeRestoredPaneStates(
            from: restoredTabsByServer,
            snapshotsByTabId: snapshotsByTabId
        )
        connectedServerIds = activeServerIds
    }

    private func schedulePersist() {
        guard !isRestoring else { return }
        persistTask?.cancel()
        persistTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            await MainActor.run {
                self?.persistSnapshot()
            }
        }
    }

    private func persistSnapshot() {
        do {
            let data = try JSONEncoder().encode(makeSnapshot())
            UserDefaults.standard.set(data, forKey: persistenceKey)
        } catch {
            logger.error("Failed to persist tabs snapshot: \(error.localizedDescription)")
        }
    }

    private func restoreSnapshot() {
        guard let data = UserDefaults.standard.data(forKey: persistenceKey) else { return }
        do {
            let snapshot = try JSONDecoder().decode(TerminalTabsSnapshot.self, from: data)
            isRestoring = true
            applyRestoredSnapshot(snapshot)
        } catch {
            logger.error("Failed to restore tabs snapshot: \(error.localizedDescription)")
        }
        isRestoring = false
    }
}

// MARK: - Persistence Snapshot

private struct TerminalTabsSnapshot: Codable {
    struct ServerSnapshot: Codable {
        let serverId: UUID
        let tabs: [TabSnapshot]
        let selectedTabId: UUID?
        let selectedView: String?
    }

    struct TabSnapshot: Codable {
        let id: UUID
        let serverId: UUID
        let title: String
        let createdAt: Date
        let layout: TerminalSplitNode?
        let focusedPaneId: UUID
        let rootPaneId: UUID
        let panePresentationOverrides: [UUID: TerminalPresentationOverrides]?

        init(from tab: TerminalTab, paneStates: [UUID: TerminalPaneState]) {
            self.id = tab.id
            self.serverId = tab.serverId
            self.title = tab.title
            self.createdAt = tab.createdAt
            self.layout = tab.layout
            self.focusedPaneId = tab.focusedPaneId
            self.rootPaneId = tab.rootPaneId
            let overrides: [UUID: TerminalPresentationOverrides] = Dictionary(
                uniqueKeysWithValues: tab.allPaneIds.compactMap { paneId in
                    guard let overrides = paneStates[paneId]?.presentationOverrides,
                          !overrides.isEmpty else {
                        return nil
                    }
                    return (paneId, overrides)
                }
            )
            self.panePresentationOverrides = overrides.isEmpty ? nil : overrides
        }

        func toTerminalTab() -> TerminalTab {
            TerminalTab(
                id: id,
                serverId: serverId,
                title: title,
                createdAt: createdAt,
                rootPaneId: rootPaneId,
                focusedPaneId: focusedPaneId,
                layout: layout
            )
        }
    }

    let servers: [ServerSnapshot]
}

#if DEBUG
extension TerminalTabManager {
    /// Resets manager state for deterministic integration tests.
    func resetForTesting() async {
        persistTask?.cancel()
        persistTask = nil
        for serverId in Array(serverTeardownTasks.keys) {
            await waitForServerTeardownTasks(serverId)
        }

        let allPaneIds = Set(paneStates.keys)
            .union(shellRegistry.startsInFlight.keys)
        for paneId in allPaneIds {
            clearTmuxRuntimeState(for: paneId)
        }

        var uniqueClients: [ObjectIdentifier: SSHClient] = [:]
        for registration in shellRegistry.registrations.values {
            uniqueClients[ObjectIdentifier(registration.client)] = registration.client
        }
        for context in shellRegistry.startsInFlight.values {
            uniqueClients[ObjectIdentifier(context.client)] = context.client
        }

        let terminals = terminalSurfaceRegistry.removeAll(cleanup: false)
        isRestoring = true
        tabsByServer = [:]
        selectedTabByServer = [:]
        connectedServerIds = []
        selectedViewByServer = [:]
        paneStates = [:]
        tmuxAttachPrompt = nil
        terminalRegistryVersion = 0
        shellRegistry.removeAll()
        tabOpensInFlight.removeAll()
        serverTeardownTasks.removeAll()
        paneRuntimes.removeAll()
        terminalConnectionRegistry.removeAll()
        testingTerminalConnectionClientFactory = nil
        tmuxCleanupServers.removeAll()
        isRestoring = false

        UserDefaults.standard.removeObject(forKey: persistenceKey)
        for terminal in terminals {
            terminal.cleanup()
        }
        for client in uniqueClients.values {
            await client.disconnect()
        }
    }

    func setTerminalConnectionClientFactoryForTesting(
        _ factory: @escaping @MainActor (TerminalEntityID, Server?) -> any TerminalConnectionClient
    ) {
        testingTerminalConnectionClientFactory = factory
    }

    func startRuntimeForTesting(paneId: UUID) async {
        guard let paneState = paneStates[paneId],
              let factory = testingTerminalConnectionClientFactory else {
            return
        }

        let server = ServerManager.shared.servers.first { $0.id == paneState.serverId }
        let entityId = TerminalEntityID.pane(paneId)
        let client = factory(entityId, server)
        let runtime = TerminalConnectionRuntime(
            entityId: entityId,
            clientFactory: { client }
        )
        terminalConnectionRegistry.register(runtime, for: entityId, serverId: paneState.serverId)
        await runtime.open(configuration: .testing)
        if await runtime.state == .streaming {
            updatePaneState(paneId, connectionState: .connected)
        }
    }

    func restorePersistedSnapshotForTesting() {
        restoreSnapshot()
    }
}
#endif
