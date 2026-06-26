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

    typealias PaneCloseResult = TerminalTabManagerSupport.PaneCloseResult
    typealias TabCloseResult = TerminalTabManagerSupport.TabCloseResult
    typealias TmuxInstallRequest = TerminalTabManagerSupport.TmuxInstallRequest
    typealias MoshInstallRequest = TerminalTabManagerSupport.MoshInstallRequest
    typealias PaneRetryRequest = TerminalTabManagerSupport.PaneRetryRequest
    typealias PaneHostRetrustRequest = TerminalTabManagerSupport.PaneHostRetrustRequest
    typealias PaneCredentialLoadRequest = TerminalTabManagerSupport.PaneCredentialLoadRequest
    typealias SurfaceAttachRequest = TerminalTabManagerSupport.SurfaceAttachRequest
    typealias InputRequest = TerminalTabManagerSupport.InputRequest
    typealias RichPasteUploadRequest = TerminalTabManagerSupport.RichPasteUploadRequest
    typealias ResizeRequest = TerminalTabManagerSupport.ResizeRequest
    typealias ProcessExitRequest = TerminalTabManagerSupport.ProcessExitRequest
    typealias PaneRuntimeState = TerminalTabManagerSupport.PaneRuntimeState

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

    /// Legacy alias for servers with live terminal transports. Open tabs are tracked by `openServerIds`.
    var connectedServerIds: Set<UUID> {
        activeServerIds
    }

    var openServerIds: Set<UUID> {
        Set(tabsByServer.keys)
    }

    var activeServerIds: Set<UUID> {
        terminalConnectionRegistry.activeServerIds
    }

    var hasLivePanes: Bool {
        terminalConnectionRegistry.hasStreamingEntity
    }

    func hasLiveRuntime(forPaneId paneId: UUID) -> Bool {
        terminalConnectionRegistry.isOpeningOrStreaming(.pane(paneId))
    }

    func shouldAutoReconnectPane(
        _ paneId: UUID,
        isSceneActive: Bool,
        autoReconnectEnabled: Bool,
        reconnectInFlight: Bool = false,
        isSuspendingForBackground: Bool = false
    ) -> Bool {
        guard let state = paneStates[paneId]?.connectionState else { return false }
        return TerminalAutoReconnectPolicy.shouldAttemptReconnect(
            isSceneActive: isSceneActive,
            autoReconnectEnabled: autoReconnectEnabled,
            reconnectInFlight: reconnectInFlight || reconnectInFlightStore.contains(paneId),
            isSuspendingForBackground: isSuspendingForBackground,
            connectionState: state,
            hasLiveRuntime: hasLiveRuntime(forPaneId: paneId)
        )
    }

    func shouldManuallyReconnectPane(
        _ paneId: UUID,
        reconnectInFlight: Bool
    ) -> Bool {
        guard let state = paneStates[paneId]?.connectionState else { return false }
        return TerminalManualReconnectPolicy.shouldAttemptReconnect(
            reconnectInFlight: reconnectInFlight || reconnectInFlightStore.contains(paneId),
            snapshotState: state,
            hasLiveRuntime: hasLiveRuntime(forPaneId: paneId)
        )
    }

    /// Selected view type per server (stats/terminal)
    @Published var selectedViewByServer: [UUID: String] = [:] {
        didSet { schedulePersist() }
    }

    // MARK: - Terminal Registry

    /// Terminal UI surfaces keyed by pane entity. SSH runtime ownership is separate.
    let terminalSurfaceRegistry = TerminalSurfaceRegistry()
    var shellRegistry = SSHShellRegistry(staleThreshold: 120)
    /// Server IDs with an in-flight tab-open request to avoid queued duplicates.
    private var tabOpenRequestStore = TerminalOpenRequestStore()
    private(set) var lastTabOpenFailure: Error?
    var pendingTabOpenRequestIDs: Set<UUID> { tabOpenRequestStore.pendingRequestIDs }
    var tmuxInstallRequestStore = TerminalScopedRequestStore<TmuxInstallRequest>()
    var pendingTmuxInstallRequestIDs: Set<UUID> { tmuxInstallRequestStore.pendingRequestIDs }
    var moshInstallRequestStore = TerminalScopedRequestStore<MoshInstallRequest>()
    private(set) var lastMoshInstallFailure: Error?
    var pendingMoshInstallRequestIDs: Set<UUID> { moshInstallRequestStore.pendingRequestIDs }
    var paneRetryRequestStore = TerminalScopedRequestStore<PaneRetryRequest>()
    var pendingPaneRetryRequestIDs: Set<UUID> { paneRetryRequestStore.pendingRequestIDs }
    var paneHostRetrustRequestStore = TerminalScopedRequestStore<PaneHostRetrustRequest>()
    var pendingPaneHostRetrustRequestIDs: Set<UUID> { paneHostRetrustRequestStore.pendingRequestIDs }
    var paneCredentialLoadRequestStore = TerminalScopedRequestStore<PaneCredentialLoadRequest>()
    var pendingPaneCredentialLoadRequestIDs: Set<UUID> { paneCredentialLoadRequestStore.pendingScopedRequestIDs }
    var surfaceAttachRequestStore = TerminalScopedRequestStore<SurfaceAttachRequest>()
    var pendingSurfaceAttachRequestIDs: Set<UUID> { surfaceAttachRequestStore.pendingRequestIDs }
    var inputRequestStore = TerminalSerialRequestStore<InputRequest>()
    var pendingInputRequestIDs: Set<UUID> { inputRequestStore.pendingRequestIDs }
    var richPasteUploadRequestStore = TerminalScopedRequestStore<RichPasteUploadRequest>()
    var pendingPaneRichPasteUploadRequestIDs: Set<UUID> { richPasteUploadRequestStore.pendingRequestIDs }
    var resizeRequestStore = TerminalScopedRequestStore<ResizeRequest>()
    var pendingResizeRequestIDs: Set<UUID> { resizeRequestStore.pendingRequestIDs }
    var processExitRequestStore = TerminalScopedRequestStore<ProcessExitRequest>()
    var pendingProcessExitRequestIDs: Set<UUID> { processExitRequestStore.pendingRequestIDs }
    private var serverUnlocker: @MainActor (Server) async -> Bool = { server in
        await AppLockManager.shared.ensureServerUnlocked(server)
    }
    var reconnectInFlightStore = TerminalReconnectInFlightStore()
    /// In-flight SSH teardown tasks by server, used to serialize close/open ordering.
    var serverTeardownTaskStore = TerminalTeardownTaskStore()
    /// Application-owned connect watchdog timers keyed by pane.
    private var connectWatchdogStore = TerminalConnectWatchdogStore()
    var credentialsProvider: @MainActor (Server) async throws -> ServerCredentials = { server in
        try KeychainManager.shared.getCredentials(for: server)
    }
    /// Application-owned pane SSH runtimes. SwiftUI coordinators attach surfaces and send intent only.
    var paneRuntimes: [UUID: PaneRuntimeState] = [:]
    let terminalConnectionRegistry = TerminalConnectionRegistry()
    var successfulConnectionRecorder: @MainActor (_ id: UUID, _ transport: String) -> Void = {
        EngagementTracker.shared.recordSuccessfulConnection(id: $0, transport: $1)
    }
    #if DEBUG
    private var testingTerminalConnectionClientFactory: (@MainActor (TerminalEntityID, Server?) -> any TerminalConnectionClient)?
    var rejectedShellCleanupOperationForTesting: (@MainActor @Sendable () async -> Void)?
    var tmuxKillOperationForTesting: (@MainActor @Sendable () async -> Void)?
    var tmuxInstallOperationForTesting: (@MainActor (UUID) async -> Void)?
    var moshInstallAndReconnectOperationForTesting: (@MainActor (UUID) async throws -> Void)?
    var paneRetryOperationForTesting: (@MainActor (UUID, Server) async -> TerminalReconnectRequestResult)?
    var paneHostRetrustOperationForTesting: (@MainActor (UUID, Server) async -> Bool)?
    private var surfaceAttachOperationForTesting: (@MainActor (TerminalEntityID) async -> Void)?
    var inputOperationForTesting: (@MainActor (Data, TerminalEntityID) async -> Void)?
    var richPasteLeaseProviderForTesting: (@MainActor (UUID) -> RemoteConnectionLease?)?
    var richPasteUploadOperationForTesting: TerminalRichPasteUploadOperation?
    var resizeOperationForTesting: (@MainActor (TerminalResizeRequestSize, TerminalEntityID) async -> Void)?
    private var processExitOperationForTesting: (@MainActor (TerminalEntityID) async -> Void)?
    #endif

    /// Pane state keyed by pane ID
    @Published var paneStates: [UUID: TerminalPaneState] = [:]
    @Published var runtimeTitleByPane: [UUID: String] = [:]

    @Published var tmuxAttachPrompt: TmuxAttachPrompt?

    let tmuxResolver = TmuxAttachResolver()

    /// Bumps when a terminal view is registered/unregistered so views refresh.
    @Published private(set) var terminalRegistryVersion: Int = 0

    func bumpTerminalRegistryVersion() {
        terminalRegistryVersion &+= 1
    }

    /// Servers that already ran tmux cleanup (per app launch)
    var tmuxCleanupStore = TerminalTmuxCleanupStore()

    let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "TerminalTabManager")

    let snapshotStore = TerminalTabsSnapshotStore()
    var persistTask: Task<Void, Never>?
    var isRestoring = false

    private init() {
        restoreSnapshot()
    }

    func setLastMoshInstallFailure(_ error: Error?) {
        lastMoshInstallFailure = error
    }

    func paneTmuxStatus(for paneId: UUID) -> TmuxStatus? {
        paneStates[paneId]?.tmuxStatus
    }

    func setPaneTmuxStatus(_ status: TmuxStatus, for paneId: UUID) {
        paneStates[paneId]?.tmuxStatus = status
    }

    func paneWorkingDirectory(for paneId: UUID) -> String? {
        paneStates[paneId]?.workingDirectory
    }

    func setPaneWorkingDirectory(_ workingDirectory: String, for paneId: UUID) {
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
            trackShellCleanup(
                for: staleContext.serverId,
                reason: "stale pane start"
            ) { [client = staleContext.client] in
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

    @discardableResult
    func requestTabOpen(
        for server: Server,
        selectTerminalViewOnSuccess: Bool = false,
        onOpened: @escaping @MainActor (TerminalTab) -> Void = { _ in },
        onFailed: @escaping @MainActor (Error) -> Void = { _ in }
    ) -> UUID {
        let requestID = UUID()
        lastTabOpenFailure = nil

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.tabOpenRequestStore.remove(id: requestID) }

            do {
                let tab = try await self.openTab(for: server)
                if selectTerminalViewOnSuccess {
                    self.selectedViewByServer[server.id] = ViewTabConfigurationManager.shared.effectiveDefaultTab()
                }
                onOpened(tab)
            } catch is CancellationError {
                return
            } catch {
                self.lastTabOpenFailure = error
                onFailed(error)
            }
        }

        tabOpenRequestStore.insert(task, id: requestID)
        return requestID
    }

    @discardableResult
    func requestServerTerminalOpen(
        for server: Server,
        selectTerminalViewOnSuccess: Bool = false,
        onOpened: @escaping @MainActor (TerminalTab) -> Void = { _ in },
        onFailed: @escaping @MainActor (Error) -> Void = { _ in }
    ) -> UUID {
        let requestID = UUID()
        lastTabOpenFailure = nil

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.tabOpenRequestStore.remove(id: requestID) }

            do {
                guard await self.serverUnlocker(server) else {
                    throw VVTermError.authenticationFailed
                }

                if let tab = self.selectedTab(for: server.id) ?? self.tabs(for: server.id).first {
                    if selectTerminalViewOnSuccess {
                        self.selectedViewByServer[server.id] = ViewTabConfigurationManager.shared.effectiveDefaultTab()
                    }
                    onOpened(tab)
                    return
                }

                let tab = try await self.openTab(for: server, shouldEnsureUnlocked: false)
                if selectTerminalViewOnSuccess {
                    self.selectedViewByServer[server.id] = ViewTabConfigurationManager.shared.effectiveDefaultTab()
                }
                onOpened(tab)
            } catch is CancellationError {
                return
            } catch {
                self.lastTabOpenFailure = error
                onFailed(error)
            }
        }

        tabOpenRequestStore.insert(task, id: requestID)
        return requestID
    }

    func waitForTabOpenRequest(_ requestID: UUID) async {
        await tabOpenRequestStore[requestID]?.value
    }

    func waitForSurfaceAttachRequest(_ requestID: UUID) async {
        await surfaceAttachRequestStore[requestID]?.task.value
    }

    func waitForProcessExitRequest(_ requestID: UUID) async {
        await processExitRequestStore[requestID]?.task.value
    }

    /// Open a new tab for a server
    @discardableResult
    func openTab(for server: Server) async throws -> TerminalTab {
        try await openTab(for: server, shouldEnsureUnlocked: true)
    }

    @discardableResult
    private func openTab(for server: Server, shouldEnsureUnlocked: Bool) async throws -> TerminalTab {
        await waitForServerTeardownTasks(server.id)

        if !tabOpenRequestStore.beginOpen(forScope: server.id) {
            throw VVTermError.connectionFailed(
                String(localized: "A tab is already opening for this server.")
            )
        }
        defer { tabOpenRequestStore.finishOpen(forScope: server.id) }

        if shouldEnsureUnlocked {
            guard await serverUnlocker(server) else {
                throw VVTermError.authenticationFailed
            }
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

        let newPaneId = UUID()
        guard let split = TerminalTabSplitPolicy.split(
            tab: currentTab,
            targetPaneId: paneId,
            newPaneId: newPaneId,
            direction: direction,
            sourcePaneState: paneStates[paneId],
            isTmuxEnabled: tmuxResolver.isTmuxEnabled(for: currentTab.serverId)
        ) else {
            logger.warning("splitPane: pane not found \(paneId.uuidString, privacy: .public)")
            return nil
        }

        // Store pane state before @Published tab updates so rendering can resolve it immediately.
        paneStates[newPaneId] = split.newPaneState

        updateTab(split.updatedTab)

        logger.info("Split pane \(paneId) \(direction.rawValue), new pane: \(newPaneId)")
        return newPaneId
    }

    /// Update a tab in the tabs array
    func updateTab(_ tab: TerminalTab) {
        guard var serverTabs = tabsByServer[tab.serverId],
              let index = serverTabs.firstIndex(where: { $0.id == tab.id }) else { return }
        serverTabs[index] = tab
        tabsByServer[tab.serverId] = serverTabs
        updateTmuxFocus(for: tab)
    }

    /// Send text to the terminal surface for a given split pane.
    func sendText(_ text: String, toPane paneId: UUID) {
        guard let terminal = terminalSurfaceRegistry.surface(for: .pane(paneId)) else { return }
        terminal.sendText(text)
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

        let entityId = TerminalEntityID.pane(paneId)
        let runtime = makeTerminalConnectionRuntime(entityId: entityId, server: server)
        terminalConnectionRegistry.register(runtime, for: entityId, serverId: server.id)
        paneRuntimes[paneId] = PaneRuntimeState(
            paneId: paneId,
            server: server,
            credentials: credentials,
            runtime: runtime,
            onProcessExit: onProcessExit
        )
    }

    private func makeTerminalConnectionRuntime(
        entityId: TerminalEntityID,
        server: Server?
    ) -> TerminalConnectionRuntime {
        #if DEBUG
        if let testingTerminalConnectionClientFactory {
            return TerminalConnectionRuntime(
                entityId: entityId,
                clientFactory: { testingTerminalConnectionClientFactory(entityId, server) }
            )
        }
        #endif

        return TerminalConnectionRuntime(entityId: entityId)
    }

    func startRuntimeIfNeeded(forPane paneId: UUID, terminal: GhosttyTerminalView) async {
        guard let runtime = runtimeStateForStarting(paneId: paneId) else { return }
        await startRuntimeIfNeeded(runtime, terminal: terminal)
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

    private func startRuntimeIfNeeded(_ runtime: PaneRuntimeState, terminal: any TerminalConnectionSurface) async {
        let paneId = runtime.paneId

        if await runtime.runtime.hasShellTask() {
            logger.debug("Ignoring duplicate start request for pane \(paneId.uuidString, privacy: .public)")
            return
        }

        if let existingShellId = shellId(for: paneId) {
            await runtime.runtime.setShellId(existingShellId)
            updatePaneState(paneId, connectionState: .connected)
            logger.debug("Reusing existing shell for pane \(paneId.uuidString, privacy: .public)")
            return
        }

        if await runtime.runtime.currentShellId() != nil {
            updatePaneState(paneId, connectionState: .connected)
            return
        }

        let sshClient = await runtime.runtime.runnerClient()
        guard let startResult = beginShellStart(for: paneId, client: sshClient),
              startResult.started else {
            if shellId(for: paneId) != nil {
                updatePaneState(paneId, connectionState: .connected)
            }
            logger.debug("Shell start already in progress for pane \(paneId.uuidString, privacy: .public)")
            return
        }

        let server = runtime.server
        let credentials = runtime.credentials
        let onProcessExit = runtime.onProcessExit
        let logger = self.logger
        let shellGeneration = startResult.generation

        let shellTask = Task.detached(priority: .userInitiated) { [weak terminal] in
            defer {
                Task { @MainActor in
                    TerminalTabManager.shared.finishShellStart(
                        for: paneId,
                        client: sshClient,
                        generation: shellGeneration
                    )
                    if let runtime = TerminalTabManager.shared.paneRuntimes[paneId]?.runtime {
                        await runtime.clearShellTask(ifUsing: sshClient)
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
                    let accepted = TerminalTabManager.shared.registerSSHClient(
                        sshClient,
                        shellId: shell.id,
                        for: paneId,
                        serverId: server.id,
                        transport: shell.transport,
                        fallbackReason: shell.fallbackReason,
                        generation: shellGeneration,
                        skipTmuxLifecycle: skipTmuxLifecycle
                    )
                    guard accepted else { return false }
                    await TerminalTabManager.shared.paneRuntimes[paneId]?.runtime.setShellId(shell.id)
                    TerminalTabManager.shared.updatePaneState(paneId, connectionState: .connected)
                    return true
                },
                onBeforeShellStart: { cols, rows in
                    await TerminalTabManager.shared.paneRuntimes[paneId]?.runtime.updateLastSize(cols: cols, rows: rows)
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
                    terminal.writeConnectionOutput(data)
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
                        terminal.writeConnectionOutput(data)
                    }
                    TerminalTabManager.shared.updatePaneState(paneId, connectionState: .failed(error.localizedDescription))
                }
            )
        }
        await runtime.runtime.setShellTask(shellTask)
    }

    func registeredShellRoute(forPane paneId: UUID) -> (client: SSHClient, shellId: UUID)? {
        guard let client = getSSHClient(for: paneId),
              let shellId = shellId(for: paneId) else {
            return nil
        }
        return (client: client, shellId: shellId)
    }

    func cancelRuntime(
        forPane paneId: UUID,
        mode: ShellTeardownMode,
        cleanupTerminal: Bool,
        closeRegisteredShell: Bool
    ) async {
        let runtime = paneRuntimes[paneId]
        await runtime?.runtime.cancelShellTask()
        let shellId = await runtime?.runtime.clearShellId()

        if cleanupTerminal {
            terminalSurfaceRegistry.removeSurface(for: .pane(paneId), cleanup: true)
        }

        guard let runtime else { return }
        if closeRegisteredShell, let shellId {
            await runtime.runtime.closeRunnerShell(shellId)
        }
        if mode == .fullDisconnect {
            if closeRegisteredShell {
                await runtime.runtime.disconnectRunnerClientAndClear()
            }
            paneRuntimes.removeValue(forKey: paneId)
            terminalConnectionRegistry.discardRuntime(for: .pane(paneId))
        }
    }

    func closeTestingRuntimeIfNeeded(forPane paneId: UUID) async -> Bool {
        guard let runtime = terminalConnectionRegistry.runtime(for: .pane(paneId)) else {
            return false
        }
        await runtime.close(mode: .fullDisconnect)
        terminalConnectionRegistry.discardRuntime(for: .pane(paneId))
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
    @discardableResult
    func registerSSHClient(
        _ client: SSHClient,
        shellId: UUID,
        for paneId: UUID,
        serverId: UUID,
        transport: ShellTransport = .ssh,
        fallbackReason: MoshFallbackReason? = nil,
        skipTmuxLifecycle: Bool = false
    ) -> Bool {
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

    @discardableResult
    func registerSSHClient(
        _ client: SSHClient,
        shellId: UUID,
        for paneId: UUID,
        serverId: UUID,
        transport: ShellTransport = .ssh,
        fallbackReason: MoshFallbackReason? = nil,
        generation: SSHShellRegistry.Generation?,
        skipTmuxLifecycle: Bool = false
    ) -> Bool {
        guard paneStates[paneId] != nil else {
            logger.warning("Ignoring shell registration for missing pane \(paneId.uuidString, privacy: .public)")
            trackShellCleanup(
                for: serverId,
                reason: "missing pane shell"
            ) { [client, shellId] in
                await client.closeShell(shellId)
                await client.disconnect()
            }
            return false
        }

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
            trackShellCleanup(
                for: serverId,
                reason: "rejected pane shell"
            ) { [client = stale.client, shellId = stale.shellId] in
                await client.closeShell(shellId)
                await client.disconnect()
            }
            return false
        }

        if let replaced = registerResult.replacedShell {
            trackShellCleanup(
                for: serverId,
                reason: "replaced pane shell"
            ) { [client = replaced.client, shellId = replaced.shellId] in
                await client.closeShell(shellId)
            }
        }

        setPaneTransport(transport, fallbackReason: fallbackReason, for: paneId)

        if !skipTmuxLifecycle {
            Task { [weak self] in
                await self?.handleTmuxLifecycle(paneId: paneId, serverId: serverId, client: client, shellId: shellId)
            }
        }
        return true
    }

    /// Unregister SSH shell
    func unregisterSSHClient(for paneId: UUID) async {
        await unregisterSSHClient(for: paneId, killingManagedTmuxSessionNamed: nil)
    }

    func unregisterSSHClient(
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
    private func getSSHClient(for paneId: UUID) -> SSHClient? {
        shellRegistry.client(for: paneId)
    }

    func remoteConnectionLease(for paneId: UUID) -> RemoteConnectionLease? {
        getSSHClient(for: paneId).map {
            RemoteConnectionLease(client: $0, ownership: .borrowed)
        }
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
    private func sshClient(for serverId: UUID) -> SSHClient? {
        preferredSSHClient(for: serverId, allowPendingStart: true)
    }

    /// Returns only clients that already have a registered shell for this server.
    private func activeSSHClient(for serverId: UUID) -> SSHClient? {
        preferredSSHClient(for: serverId, allowPendingStart: false)
    }

    func hasOtherActivePanes(for serverId: UUID, excluding paneId: UUID) -> Bool {
        terminalConnectionRegistry.hasActiveEntity(
            for: serverId,
            excluding: .pane(paneId)
        )
    }

    func handlePaneExit(for paneId: UUID) async {
        guard paneStates[paneId] != nil else { return }
        updatePaneState(paneId, connectionState: .disconnected)
        await unregisterSSHClient(for: paneId)
    }

    @discardableResult
    func requestPaneProcessExit(forPane paneId: UUID) -> UUID? {
        guard paneStates[paneId] != nil else { return nil }

        if let existingRequestID = processExitRequestStore.requestID(forScope: paneId) {
            return existingRequestID
        }

        let requestID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.processExitRequestStore.remove(id: requestID, ifMappedTo: paneId)
            }

            guard !Task.isCancelled else { return }
            guard self.paneStates[paneId] != nil else { return }

            #if DEBUG
            if let processExitOperationForTesting = self.processExitOperationForTesting {
                await processExitOperationForTesting(.pane(paneId))
                return
            }
            #endif

            await self.handlePaneExit(for: paneId)
        }

        processExitRequestStore.insert(
            ProcessExitRequest(paneId: paneId, task: task),
            id: requestID,
            scopeID: paneId
        )
        return requestID
    }

    func shouldScheduleConnectWatchdog(
        forPaneId paneId: UUID,
        isReady: Bool,
        terminalExists: Bool
    ) -> Bool {
        guard let state = paneStates[paneId]?.connectionState else { return false }
        return state.isConnecting || (state.isConnected && !isReady && !terminalExists)
    }

    func scheduleConnectWatchdog(
        forPaneId paneId: UUID,
        isReady: Bool,
        terminalExists: Bool,
        timeout: Duration = .seconds(20),
        timeoutMessage: String,
        onRetry: @escaping @MainActor () async -> Void
    ) {
        connectWatchdogStore.removeTask(for: paneId)?.cancel()

        guard shouldScheduleConnectWatchdog(
            forPaneId: paneId,
            isReady: isReady,
            terminalExists: terminalExists
        ) else {
            connectWatchdogStore.clear(for: paneId)?.cancel()
            return
        }

        let generation = connectWatchdogStore.beginGeneration(for: paneId)
        let task = Task { @MainActor [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            guard let self else { return }
            guard self.connectWatchdogStore.isCurrent(generation, for: paneId) else { return }

            let action = self.handleConnectWatchdogTimeout(
                forPaneId: paneId,
                isReady: isReady,
                terminalExists: terminalExists,
                timeoutMessage: timeoutMessage
            )

            switch action {
            case .retry:
                self.connectWatchdogStore.clear(for: paneId)
                await onRetry()
            case .continueWatching:
                self.scheduleConnectWatchdog(
                    forPaneId: paneId,
                    isReady: isReady,
                    terminalExists: terminalExists,
                    timeout: timeout,
                    timeoutMessage: timeoutMessage,
                    onRetry: onRetry
                )
            case .none:
                self.connectWatchdogStore.clear(for: paneId)
            }
        }
        connectWatchdogStore.setTask(task, for: paneId)
    }

    func handleConnectWatchdogTimeout(
        forPaneId paneId: UUID,
        isReady: Bool,
        terminalExists: Bool,
        timeoutMessage: String
    ) -> TerminalConnectWatchdogAction {
        guard let state = paneStates[paneId]?.connectionState else { return .none }
        let connectedWithoutTerminal = state.isConnected && !isReady && !terminalExists
        guard state.isConnecting || connectedWithoutTerminal else { return .none }

        if connectedWithoutTerminal {
            updatePaneState(paneId, connectionState: .disconnected)
            return .retry
        }

        if shellId(for: paneId) != nil {
            updatePaneState(paneId, connectionState: .connected)
            return .none
        }

        if isShellStartInFlight(for: paneId) {
            return .continueWatching
        }

        updatePaneState(paneId, connectionState: .failed(timeoutMessage))
        return .none
    }

    /// Returns true when the same SSH client instance is registered to another live pane.
    /// This is used to avoid disconnecting a truly shared client during retry cleanup.
    func hasOtherRegistrations(using client: SSHClient, excluding paneId: UUID) -> Bool {
        shellRegistry.hasOtherRegistrations(using: client, excluding: paneId)
    }

    private func sharedStatsClient(for serverId: UUID) -> SSHClient? {
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

    func sharedStatsLease(for serverId: UUID) -> RemoteConnectionLease? {
        sharedStatsClient(for: serverId).map {
            RemoteConnectionLease(client: $0, ownership: .borrowed)
        }
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
            successfulConnectionRecorder(
                paneId,
                successfulConnectionTransport(for: paneId).rawValue
            )
        case .idle:
            break
        }
    }

    private func successfulConnectionTransport(for paneId: UUID) -> ShellTransport {
        shellRegistry.registration(for: paneId)?.transport
            ?? .ssh
    }

    var hasConnectedPanes: Bool {
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

}

#if DEBUG
extension TerminalTabManager {
    /// Resets manager state for deterministic integration tests.
    func resetForTesting() async {
        persistTask?.cancel()
        persistTask = nil
        for serverId in serverTeardownTaskStore.serverIDs {
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
        successfulConnectionRecorder = { EngagementTracker.shared.recordSuccessfulConnection(id: $0, transport: $1) }
        tabsByServer = [:]
        selectedTabByServer = [:]
        selectedViewByServer = [:]
        paneStates = [:]
        tmuxAttachPrompt = nil
        terminalRegistryVersion = 0
        shellRegistry.removeAll()
        tabOpenRequestStore.removeAll().forEach { $0.cancel() }
        lastTabOpenFailure = nil
        tmuxInstallRequestStore.allRequests.forEach { $0.task.cancel() }
        tmuxInstallRequestStore.removeAll()
        moshInstallRequestStore.allRequests.forEach { $0.task.cancel() }
        moshInstallRequestStore.removeAll()
        lastMoshInstallFailure = nil
        paneRetryRequestStore.allRequests.forEach { $0.task.cancel() }
        paneRetryRequestStore.removeAll()
        paneHostRetrustRequestStore.allRequests.forEach { $0.task.cancel() }
        paneHostRetrustRequestStore.removeAll()
        paneCredentialLoadRequestStore.allRequests.forEach { $0.task.cancel() }
        paneCredentialLoadRequestStore.removeAll()
        surfaceAttachRequestStore.allRequests.forEach { $0.task.cancel() }
        surfaceAttachRequestStore.removeAll()
        inputRequestStore.allRequests.forEach { $0.task.cancel() }
        inputRequestStore.removeAll()
        let richPasteUploadTasks = richPasteUploadRequestStore.allRequests.map(\.task)
        richPasteUploadTasks.forEach { $0.cancel() }
        for task in richPasteUploadTasks {
            await task.value
        }
        richPasteUploadRequestStore.removeAll()
        resizeRequestStore.allRequests.forEach { $0.task.cancel() }
        resizeRequestStore.removeAll()
        processExitRequestStore.allRequests.forEach { $0.task.cancel() }
        processExitRequestStore.removeAll()
        reconnectInFlightStore.removeAll()
        connectWatchdogStore.removeAll().forEach { $0.cancel() }
        credentialsProvider = { server in
            try KeychainManager.shared.getCredentials(for: server)
        }
        serverUnlocker = { server in
            await AppLockManager.shared.ensureServerUnlocked(server)
        }
        serverTeardownTaskStore.removeAll()
        paneRuntimes.removeAll()
        terminalConnectionRegistry.removeAll()
        testingTerminalConnectionClientFactory = nil
        rejectedShellCleanupOperationForTesting = nil
        tmuxKillOperationForTesting = nil
        tmuxInstallOperationForTesting = nil
        moshInstallAndReconnectOperationForTesting = nil
        paneRetryOperationForTesting = nil
        paneHostRetrustOperationForTesting = nil
        surfaceAttachOperationForTesting = nil
        inputOperationForTesting = nil
        richPasteLeaseProviderForTesting = nil
        richPasteUploadOperationForTesting = nil
        resizeOperationForTesting = nil
        processExitOperationForTesting = nil
        tmuxCleanupStore.removeAll()
        isRestoring = false

        snapshotStore.remove()
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

    func setSurfaceAttachOperationForTesting(
        _ operation: (@MainActor (TerminalEntityID) async -> Void)?
    ) {
        surfaceAttachOperationForTesting = operation
    }

    func setInputOperationForTesting(
        _ operation: (@MainActor (Data, TerminalEntityID) async -> Void)?
    ) {
        inputOperationForTesting = operation
    }

    func setRichPasteLeaseProviderForTesting(
        _ provider: (@MainActor (UUID) -> RemoteConnectionLease?)?
    ) {
        richPasteLeaseProviderForTesting = provider
    }

    func setRichPasteUploadOperationForTesting(
        _ operation: TerminalRichPasteUploadOperation?
    ) {
        richPasteUploadOperationForTesting = operation
    }

    func setResizeOperationForTesting(
        _ operation: (@MainActor (TerminalResizeRequestSize, TerminalEntityID) async -> Void)?
    ) {
        resizeOperationForTesting = operation
    }

    func setProcessExitOperationForTesting(
        _ operation: (@MainActor (TerminalEntityID) async -> Void)?
    ) {
        processExitOperationForTesting = operation
    }

    @discardableResult
    func requestSurfaceAttachForTesting(
        paneId: UUID,
        context: TerminalSurfaceAttachContext
    ) -> UUID? {
        requestSurfaceAttach(
            paneId: paneId,
            context: context,
            attachOperation: { [weak self] in
                guard let self else { return }
                if let surfaceAttachOperationForTesting = self.surfaceAttachOperationForTesting {
                    await surfaceAttachOperationForTesting(.pane(paneId))
                }
            }
        )
    }

    func setRejectedShellCleanupOperationForTesting(
        _ operation: (@MainActor @Sendable () async -> Void)?
    ) {
        rejectedShellCleanupOperationForTesting = operation
    }

    func setTmuxKillOperationForTesting(
        _ operation: (@MainActor @Sendable () async -> Void)?
    ) {
        tmuxKillOperationForTesting = operation
    }

    func setTmuxInstallOperationForTesting(
        _ operation: (@MainActor (UUID) async -> Void)?
    ) {
        tmuxInstallOperationForTesting = operation
    }

    func setMoshInstallAndReconnectOperationForTesting(
        _ operation: (@MainActor (UUID) async throws -> Void)?
    ) {
        moshInstallAndReconnectOperationForTesting = operation
    }

    func setPaneRetryOperationForTesting(
        _ operation: (@MainActor (UUID, Server) async -> TerminalReconnectRequestResult)?
    ) {
        paneRetryOperationForTesting = operation
    }

    func setPaneHostRetrustOperationForTesting(
        _ operation: (@MainActor (UUID, Server) async -> Bool)?
    ) {
        paneHostRetrustOperationForTesting = operation
    }

    func setCredentialsProviderForTesting(
        _ provider: @escaping @MainActor (Server) async throws -> ServerCredentials
    ) {
        credentialsProvider = provider
    }

    func setServerUnlockerForTesting(
        _ unlocker: @escaping @MainActor (Server) async -> Bool
    ) {
        serverUnlocker = unlocker
    }

    func beginShellStartForTesting(
        paneId: UUID,
        serverId: UUID,
        client: SSHClient
    ) -> SSHShellRegistry.Generation {
        shellRegistry.tryBeginStart(
            for: paneId,
            serverId: serverId,
            client: client
        ).generation
    }

    func closeShellRegistrationForTesting(paneId: UUID) {
        _ = shellRegistry.closeEntity(paneId)
    }

    func hasTerminalConnectionRuntimeForTesting(_ entityId: TerminalEntityID) -> Bool {
        terminalConnectionRegistry.runtime(for: entityId) != nil
    }

    func setRuntimeShellTaskForTesting(
        paneId: UUID,
        _ task: Task<Void, Never>
    ) async {
        guard let runtime = paneRuntimes[paneId] else { return }
        await runtime.runtime.setShellTask(task)
    }

    func completeRuntimeShellStartForTesting(
        paneId: UUID,
        client: SSHClient,
        shellId: UUID,
        serverId: UUID,
        generation: SSHShellRegistry.Generation
    ) -> Bool {
        let accepted = registerSSHClient(
            client,
            shellId: shellId,
            for: paneId,
            serverId: serverId,
            generation: generation,
            skipTmuxLifecycle: true
        )
        guard accepted else { return false }
        updatePaneState(paneId, connectionState: .connected)
        return true
    }

    func startRuntimeForTesting(paneId: UUID) async {
        guard let paneState = paneStates[paneId] else {
            return
        }

        let server = ServerManager.shared.servers.first { $0.id == paneState.serverId }
        let entityId = TerminalEntityID.pane(paneId)
        let runtime: TerminalConnectionRuntime
        if let existing = terminalConnectionRegistry.runtime(for: entityId) {
            runtime = existing
        } else {
            runtime = makeTerminalConnectionRuntime(entityId: entityId, server: server)
            terminalConnectionRegistry.register(runtime, for: entityId, serverId: paneState.serverId)
        }
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
