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
        let richPasteUploadTasks: [Task<Void, Never>]
    }

    private struct TabCloseResult: Sendable {
        let serverId: UUID
        let paneCloseResults: [PaneCloseResult]
    }

    private struct TmuxInstallRequest {
        let paneId: UUID
        let task: Task<Void, Never>
        var onCompleted: [@MainActor () -> Void]
    }

    private struct MoshInstallRequest {
        let paneId: UUID
        let task: Task<Void, Never>
        var onCompleted: [@MainActor () -> Void]
        var onFailed: [@MainActor (Error) -> Void]
    }

    private struct PaneRetryRequest {
        let paneId: UUID
        let task: Task<Void, Never>
        var onCompleted: [@MainActor (TerminalReconnectRequestResult) -> Void]
    }

    private struct PaneHostRetrustRequest {
        let paneId: UUID
        let task: Task<Void, Never>
        var onCompleted: [@MainActor (Bool) -> Void]
    }

    private struct PaneCredentialLoadRequest {
        let paneId: UUID
        let task: Task<Void, Never>
        var onCompleted: [@MainActor (TerminalCredentialLoadResult) -> Void]
    }

    private struct SurfaceAttachRequest {
        let paneId: UUID
        var context: TerminalSurfaceAttachContext
        let task: Task<Void, Never>
    }

    private struct InputRequest {
        let paneId: UUID
        let task: Task<Void, Never>
    }

    private struct RichPasteUploadRequest {
        let paneId: UUID
        let task: Task<Void, Never>
    }

    private struct ResizeRequest {
        let paneId: UUID
        var size: TerminalResizeRequestSize
        let task: Task<Void, Never>
    }

    private struct ProcessExitRequest {
        let paneId: UUID
        let task: Task<Void, Never>
    }

    private final class PaneRuntimeState {
        let paneId: UUID
        var server: Server
        var credentials: ServerCredentials
        let runtime: TerminalConnectionRuntime
        var onProcessExit: () -> Void

        init(
            paneId: UUID,
            server: Server,
            credentials: ServerCredentials,
            runtime: TerminalConnectionRuntime,
            onProcessExit: @escaping () -> Void
        ) {
            self.paneId = paneId
            self.server = server
            self.credentials = credentials
            self.runtime = runtime
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
            reconnectInFlight: reconnectInFlight || paneReconnectsInFlight.contains(paneId),
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
            reconnectInFlight: reconnectInFlight || paneReconnectsInFlight.contains(paneId),
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
    private let terminalSurfaceRegistry = TerminalSurfaceRegistry()
    private var shellRegistry = SSHShellRegistry(staleThreshold: 120)
    /// Server IDs with an in-flight tab-open request to avoid queued duplicates.
    private var tabOpensInFlight: Set<UUID> = []
    private var tabOpenRequests: [UUID: Task<Void, Never>] = [:]
    private(set) var lastTabOpenFailure: Error?
    var pendingTabOpenRequestIDs: Set<UUID> { Set(tabOpenRequests.keys) }
    private var tmuxInstallRequests: [UUID: TmuxInstallRequest] = [:]
    private var tmuxInstallRequestByPane: [UUID: UUID] = [:]
    var pendingTmuxInstallRequestIDs: Set<UUID> { Set(tmuxInstallRequests.keys) }
    private var moshInstallRequests: [UUID: MoshInstallRequest] = [:]
    private var moshInstallRequestByPane: [UUID: UUID] = [:]
    private(set) var lastMoshInstallFailure: Error?
    var pendingMoshInstallRequestIDs: Set<UUID> { Set(moshInstallRequests.keys) }
    private var paneRetryRequests: [UUID: PaneRetryRequest] = [:]
    private var paneRetryRequestByPane: [UUID: UUID] = [:]
    var pendingPaneRetryRequestIDs: Set<UUID> { Set(paneRetryRequests.keys) }
    private var paneHostRetrustRequests: [UUID: PaneHostRetrustRequest] = [:]
    private var paneHostRetrustRequestByPane: [UUID: UUID] = [:]
    var pendingPaneHostRetrustRequestIDs: Set<UUID> { Set(paneHostRetrustRequests.keys) }
    private var paneCredentialLoadRequests: [UUID: PaneCredentialLoadRequest] = [:]
    private var paneCredentialLoadRequestByPane: [UUID: UUID] = [:]
    var pendingPaneCredentialLoadRequestIDs: Set<UUID> { Set(paneCredentialLoadRequestByPane.values) }
    private var surfaceAttachRequests: [UUID: SurfaceAttachRequest] = [:]
    private var surfaceAttachRequestByPane: [UUID: UUID] = [:]
    var pendingSurfaceAttachRequestIDs: Set<UUID> { Set(surfaceAttachRequests.keys) }
    private var inputRequests: [UUID: InputRequest] = [:]
    private var inputRequestByPane: [UUID: UUID] = [:]
    private var lastInputTaskByPane: [UUID: Task<Void, Never>] = [:]
    var pendingInputRequestIDs: Set<UUID> { Set(inputRequests.keys) }
    private var richPasteUploadRequests: [UUID: RichPasteUploadRequest] = [:]
    private var richPasteUploadRequestByPane: [UUID: UUID] = [:]
    var pendingPaneRichPasteUploadRequestIDs: Set<UUID> { Set(richPasteUploadRequests.keys) }
    private var resizeRequests: [UUID: ResizeRequest] = [:]
    private var resizeRequestByPane: [UUID: UUID] = [:]
    var pendingResizeRequestIDs: Set<UUID> { Set(resizeRequests.keys) }
    private var processExitRequests: [UUID: ProcessExitRequest] = [:]
    private var processExitRequestByPane: [UUID: UUID] = [:]
    var pendingProcessExitRequestIDs: Set<UUID> { Set(processExitRequests.keys) }
    private var serverUnlocker: @MainActor (Server) async -> Bool = { server in
        await AppLockManager.shared.ensureServerUnlocked(server)
    }
    private var paneReconnectsInFlight: Set<UUID> = []
    /// In-flight SSH teardown tasks by server, used to serialize close/open ordering.
    private var serverTeardownTasks: [UUID: [UUID: Task<Void, Never>]] = [:]
    /// Application-owned connect watchdog timers keyed by pane.
    private var connectWatchdogTasks: [UUID: Task<Void, Never>] = [:]
    private var connectWatchdogGenerations: [UUID: UUID] = [:]
    private var credentialsProvider: @MainActor (Server) async throws -> ServerCredentials = { server in
        try KeychainManager.shared.getCredentials(for: server)
    }
    /// Application-owned pane SSH runtimes. SwiftUI coordinators attach surfaces and send intent only.
    private var paneRuntimes: [UUID: PaneRuntimeState] = [:]
    private let terminalConnectionRegistry = TerminalConnectionRegistry()
    var successfulConnectionRecorder: @MainActor (_ id: UUID, _ transport: String) -> Void = {
        EngagementTracker.shared.recordSuccessfulConnection(id: $0, transport: $1)
    }
    #if DEBUG
    private var testingTerminalConnectionClientFactory: (@MainActor (TerminalEntityID, Server?) -> any TerminalConnectionClient)?
    private var rejectedShellCleanupOperationForTesting: (@MainActor @Sendable () async -> Void)?
    private var tmuxKillOperationForTesting: (@MainActor @Sendable () async -> Void)?
    private var tmuxInstallOperationForTesting: (@MainActor (UUID) async -> Void)?
    private var moshInstallAndReconnectOperationForTesting: (@MainActor (UUID) async throws -> Void)?
    private var paneRetryOperationForTesting: (@MainActor (UUID, Server) async -> TerminalReconnectRequestResult)?
    private var paneHostRetrustOperationForTesting: (@MainActor (UUID, Server) async -> Bool)?
    private var surfaceAttachOperationForTesting: (@MainActor (TerminalEntityID) async -> Void)?
    private var inputOperationForTesting: (@MainActor (Data, TerminalEntityID) async -> Void)?
    private var richPasteLeaseProviderForTesting: (@MainActor (UUID) -> RemoteConnectionLease?)?
    private var richPasteUploadOperationForTesting: TerminalRichPasteUploadOperation?
    private var resizeOperationForTesting: (@MainActor (TerminalResizeRequestSize, TerminalEntityID) async -> Void)?
    private var processExitOperationForTesting: (@MainActor (TerminalEntityID) async -> Void)?
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
            defer { self.tabOpenRequests.removeValue(forKey: requestID) }

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

        tabOpenRequests[requestID] = task
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
            defer { self.tabOpenRequests.removeValue(forKey: requestID) }

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

        tabOpenRequests[requestID] = task
        return requestID
    }

    func waitForTabOpenRequest(_ requestID: UUID) async {
        await tabOpenRequests[requestID]?.value
    }

    func waitForSurfaceAttachRequest(_ requestID: UUID) async {
        await surfaceAttachRequests[requestID]?.task.value
    }

    func waitForInputRequest(_ requestID: UUID) async {
        await inputRequests[requestID]?.task.value
    }

    func waitForPaneRichPasteUploadRequest(_ requestID: UUID) async {
        await richPasteUploadRequests[requestID]?.task.value
    }

    func waitForResizeRequest(_ requestID: UUID) async {
        await resizeRequests[requestID]?.task.value
    }

    func waitForProcessExitRequest(_ requestID: UUID) async {
        await processExitRequests[requestID]?.task.value
    }

    /// Open a new tab for a server
    @discardableResult
    func openTab(for server: Server) async throws -> TerminalTab {
        try await openTab(for: server, shouldEnsureUnlocked: true)
    }

    @discardableResult
    private func openTab(for server: Server, shouldEnsureUnlocked: Bool) async throws -> TerminalTab {
        await waitForServerTeardownTasks(server.id)

        if tabOpensInFlight.contains(server.id) {
            throw VVTermError.connectionFailed(
                String(localized: "A tab is already opening for this server.")
            )
        }
        tabOpensInFlight.insert(server.id)
        defer { tabOpensInFlight.remove(server.id) }

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

    /// Disconnect all tabs for every server and wait for SSH teardown to finish.
    func disconnectAllAndWait() async {
        await waitForAllServerTeardownTasks()
        for serverId in Array(tabsByServer.keys) {
            await disconnectServerAndWait(serverId)
        }
        await waitForAllServerTeardownTasks()
    }

    /// Disconnect all tabs for a server and wait for SSH teardown to finish.
    func disconnectServerAndWait(_ serverId: UUID) async {
        await waitForServerTeardownTasks(serverId)
        let closeResults = tabs(for: serverId).compactMap { closeTabUI($0) }
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

    func attachSurface(_ terminal: GhosttyTerminalView, toPane paneId: UUID) async {
        if terminalSurfaceRegistry.surface(for: .pane(paneId)) !== terminal {
            registerTerminal(terminal, for: paneId)
        }

        await startRuntimeIfNeeded(forPane: paneId, terminal: terminal)
    }

    @discardableResult
    func requestSurfaceAttach(
        paneId: UUID,
        terminal: GhosttyTerminalView,
        context: TerminalSurfaceAttachContext
    ) -> UUID? {
        requestSurfaceAttach(
            paneId: paneId,
            context: context,
            attachOperation: { [weak self, weak terminal] in
                guard let self, let terminal else { return }
                await self.attachSurface(terminal, toPane: paneId)
            }
        )
    }

    @discardableResult
    private func requestSurfaceAttach(
        paneId: UUID,
        context: TerminalSurfaceAttachContext,
        attachOperation: @escaping @MainActor () async -> Void
    ) -> UUID? {
        if let requestID = surfaceAttachRequestByPane[paneId] {
            guard shouldAcceptSurfaceAttach(paneId: paneId, context: context) else {
                surfaceAttachRequests[requestID]?.context = context
                return nil
            }
            surfaceAttachRequests[requestID]?.context = context
            return requestID
        }

        guard shouldAcceptSurfaceAttach(paneId: paneId, context: context) else { return nil }

        let requestID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.surfaceAttachRequests.removeValue(forKey: requestID)
                if self.surfaceAttachRequestByPane[paneId] == requestID {
                    self.surfaceAttachRequestByPane.removeValue(forKey: paneId)
                }
            }

            let latestContext = self.surfaceAttachRequests[requestID]?.context ?? context
            guard self.shouldAcceptSurfaceAttach(paneId: paneId, context: latestContext) else { return }
            await attachOperation()
        }

        surfaceAttachRequests[requestID] = SurfaceAttachRequest(paneId: paneId, context: context, task: task)
        surfaceAttachRequestByPane[paneId] = requestID
        return requestID
    }

    private func shouldAcceptSurfaceAttach(
        paneId: UUID,
        context: TerminalSurfaceAttachContext
    ) -> Bool {
        guard paneStates[paneId] != nil else { return false }
        guard context.isAppActive, context.isViewActive else { return false }
        guard shellId(for: paneId) == nil else { return false }
        guard !isShellStartInFlight(for: paneId) else { return false }
        return true
    }

    func detachSurface(fromPane paneId: UUID, reason: TerminalSurfaceDetachReason) async {
        switch reason {
        case .viewDisappeared:
            detachSurfaceForPaneViewDisappeared(paneId)
        case .sessionClosed:
            detachSurfaceForClosedPane(paneId)
        }
    }

    func detachSurfaceForPaneViewDisappeared(_ paneId: UUID) {
        terminalSurfaceRegistry.detachSurface(for: .pane(paneId), cleanup: false)
    }

    func detachSurfaceForClosedPane(_ paneId: UUID) {
        unregisterTerminal(for: paneId)
    }

    func sendInput(_ data: Data, toPane paneId: UUID) async {
        if let runtime = terminalConnectionRegistry.runtime(for: .pane(paneId)) {
            do {
                try await runtime.send(data)
                return
            } catch SSHError.notConnected {
                // Input can arrive before shell registration; fallback routes
                // below handle existing registered shells without noisy logs.
            } catch {
                logger.error("Failed to send to pane SSH: \(error.localizedDescription)")
            }
        }

        guard let runtime = paneRuntimes[paneId] else {
            if let route = registeredShellRoute(forPane: paneId) {
                try? await route.client.write(data, to: route.shellId)
            }
            return
        }

        if let shellId = await runtime.runtime.currentShellId(),
           let client = await runtime.runtime.runnerClientIfCreated() {
            do {
                try await client.write(data, to: shellId)
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

    @discardableResult
    func requestPaneInput(_ data: Data, toPane paneId: UUID) -> UUID? {
        guard !data.isEmpty else { return nil }
        guard paneStates[paneId] != nil else { return nil }

        let requestID = UUID()
        let previousTask = lastInputTaskByPane[paneId]
        let task = Task { @MainActor [weak self] in
            if let previousTask {
                await previousTask.value
            }

            guard let self else { return }
            defer {
                self.inputRequests.removeValue(forKey: requestID)
                if self.inputRequestByPane[paneId] == requestID {
                    self.inputRequestByPane.removeValue(forKey: paneId)
                    self.lastInputTaskByPane.removeValue(forKey: paneId)
                }
            }

            guard !Task.isCancelled else { return }
            guard self.paneStates[paneId] != nil else { return }

            #if DEBUG
            if let inputOperationForTesting = self.inputOperationForTesting {
                await inputOperationForTesting(data, .pane(paneId))
                return
            }
            #endif

            await self.sendInput(data, toPane: paneId)
        }

        inputRequests[requestID] = InputRequest(paneId: paneId, task: task)
        inputRequestByPane[paneId] = requestID
        lastInputTaskByPane[paneId] = task
        return requestID
    }

    @discardableResult
    func requestPaneRichPasteUpload(
        image: ClipboardImagePayload,
        settings: RichClipboardSettings,
        forPane paneId: UUID,
        onProgress: @escaping @MainActor (String?) -> Void = { _ in },
        onCompleted: @escaping @MainActor (TerminalRichPasteUploadRequestResult) -> Void = { _ in }
    ) -> UUID? {
        guard paneStates[paneId] != nil else { return nil }

        if let previousRequestID = richPasteUploadRequestByPane[paneId],
           let previousRequest = richPasteUploadRequests[previousRequestID] {
            previousRequest.task.cancel()
        }

        let requestID = UUID()
        let upload = richPasteUploadOperation(for: paneId)
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.richPasteUploadRequests.removeValue(forKey: requestID)
                if self.richPasteUploadRequestByPane[paneId] == requestID {
                    self.richPasteUploadRequestByPane.removeValue(forKey: paneId)
                }
            }

            guard !Task.isCancelled else {
                onCompleted(.cancelled)
                return
            }
            guard self.paneStates[paneId] != nil else {
                onCompleted(.cancelled)
                return
            }

            let result = await TerminalRichPasteUploadRequest.perform(
                image: image,
                settings: settings,
                lease: self.richPasteLease(for: paneId),
                upload: upload,
                onProgress: { message in
                    guard self.richPasteUploadRequestByPane[paneId] == requestID else { return }
                    onProgress(message)
                },
                pasteUploadedPath: { [weak self] text in
                    guard let self else { return }
                    guard self.paneStates[paneId] != nil else { return }
                    guard let inputRequestID = self.requestPaneInput(
                        Data(text.utf8),
                        toPane: paneId
                    ) else {
                        return
                    }
                    await self.waitForInputRequest(inputRequestID)
                }
            )

            if Task.isCancelled {
                onCompleted(.cancelled)
                return
            }
            onCompleted(result)
        }

        richPasteUploadRequests[requestID] = RichPasteUploadRequest(
            paneId: paneId,
            task: task
        )
        richPasteUploadRequestByPane[paneId] = requestID
        return requestID
    }

    private func richPasteLease(for paneId: UUID) -> RemoteConnectionLease? {
        #if DEBUG
        if let richPasteLeaseProviderForTesting {
            return richPasteLeaseProviderForTesting(paneId)
        }
        #endif

        return remoteConnectionLease(for: paneId)
    }

    private func richPasteUploadOperation(for paneId: UUID) -> TerminalRichPasteUploadOperation {
        #if DEBUG
        if let richPasteUploadOperationForTesting {
            return richPasteUploadOperationForTesting
        }
        #endif

        let coordinator = TerminalRichPasteCoordinator(sessionId: paneId)
        return { image, settings, client, _ in
            try await coordinator.performRichPaste(
                image: image,
                settings: settings,
                client: client
            )
        }
    }

    func resizePane(_ paneId: UUID, cols: Int, rows: Int) async {
        guard cols > 0 && rows > 0 else { return }

        if let runtime = terminalConnectionRegistry.runtime(for: .pane(paneId)) {
            do {
                try await runtime.resize(cols: cols, rows: rows)
                return
            } catch SSHError.notConnected {
                // The first resize often arrives before the remote shell exists.
            } catch {
                logger.warning("Failed to resize pane PTY: \(error.localizedDescription)")
            }
        }

        if let runtime = paneRuntimes[paneId] {
            if let shellId = await runtime.runtime.currentShellId(),
               let client = await runtime.runtime.runnerClientIfCreated() {
                do {
                    try await client.resize(cols: cols, rows: rows, for: shellId)
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

    @discardableResult
    func requestPaneResize(_ size: TerminalResizeRequestSize, forPane paneId: UUID) -> UUID? {
        guard size.isValid else { return nil }
        guard paneStates[paneId] != nil else { return nil }

        if let existingRequestID = resizeRequestByPane[paneId],
           var request = resizeRequests[existingRequestID] {
            request.size = size
            resizeRequests[existingRequestID] = request
            return existingRequestID
        }

        let requestID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.resizeRequests.removeValue(forKey: requestID)
                if self.resizeRequestByPane[paneId] == requestID {
                    self.resizeRequestByPane.removeValue(forKey: paneId)
                }
            }

            var appliedSize: TerminalResizeRequestSize?
            while !Task.isCancelled {
                guard self.paneStates[paneId] != nil else { return }
                guard let request = self.resizeRequests[requestID] else { return }
                let size = request.size
                guard size != appliedSize else { return }

                #if DEBUG
                if let resizeOperationForTesting = self.resizeOperationForTesting {
                    await resizeOperationForTesting(size, .pane(paneId))
                } else {
                    await self.resizePane(paneId, cols: size.cols, rows: size.rows)
                }
                #else
                await self.resizePane(paneId, cols: size.cols, rows: size.rows)
                #endif

                appliedSize = size
            }
        }

        resizeRequests[requestID] = ResizeRequest(paneId: paneId, size: size, task: task)
        resizeRequestByPane[paneId] = requestID
        return requestID
    }

    private func startRuntimeIfNeeded(forPane paneId: UUID, terminal: GhosttyTerminalView) async {
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

    private func closeTestingRuntimeIfNeeded(forPane paneId: UUID) async -> Bool {
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

    func reconnectPane(_ paneId: UUID) async {
        guard paneStates[paneId] != nil else { return }
        if terminalConnectionRegistry.isOpeningOrStreaming(.pane(paneId)) {
            return
        }

        updatePaneState(paneId, connectionState: .reconnecting(attempt: 1))
        await unregisterSSHClient(for: paneId)
    }

    func retryPaneConnection(
        paneId: UUID,
        server: Server
    ) async -> TerminalReconnectRequestResult {
        guard shouldManuallyReconnectPane(
            paneId,
            reconnectInFlight: paneReconnectsInFlight.contains(paneId)
        ) else {
            return .skipped
        }

        paneReconnectsInFlight.insert(paneId)
        defer { paneReconnectsInFlight.remove(paneId) }

        do {
            let credentials = try await credentialsProvider(server)
            guard canStartPaneReconnect(paneId) else {
                return .skipped
            }
            await reconnectPane(paneId)
            return .started(credentials)
        } catch {
            return .credentialLoadFailed(error.localizedDescription)
        }
    }

    @discardableResult
    func requestPaneRetry(
        paneId: UUID,
        server: Server,
        onCompleted: @escaping @MainActor (TerminalReconnectRequestResult) -> Void = { _ in }
    ) -> UUID {
        if let requestID = paneRetryRequestByPane[paneId] {
            paneRetryRequests[requestID]?.onCompleted.append(onCompleted)
            return requestID
        }

        let requestID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.paneRetryRequests.removeValue(forKey: requestID)
                if self.paneRetryRequestByPane[paneId] == requestID {
                    self.paneRetryRequestByPane.removeValue(forKey: paneId)
                }
            }

            #if DEBUG
            let result: TerminalReconnectRequestResult
            if let operation = self.paneRetryOperationForTesting {
                result = await operation(paneId, server)
            } else {
                result = await self.retryPaneConnection(paneId: paneId, server: server)
            }
            #else
            let result = await self.retryPaneConnection(paneId: paneId, server: server)
            #endif

            let callbacks = self.paneRetryRequests[requestID]?.onCompleted ?? []
            callbacks.forEach { $0(Task.isCancelled ? .skipped : result) }
        }
        paneRetryRequests[requestID] = PaneRetryRequest(
            paneId: paneId,
            task: task,
            onCompleted: [onCompleted]
        )
        paneRetryRequestByPane[paneId] = requestID
        return requestID
    }

    func waitForPaneRetryRequest(_ requestID: UUID) async {
        await paneRetryRequests[requestID]?.task.value
    }

    private func canStartPaneReconnect(_ paneId: UUID) -> Bool {
        guard let state = paneStates[paneId]?.connectionState else { return false }
        return TerminalManualReconnectPolicy.shouldAttemptReconnect(
            reconnectInFlight: false,
            snapshotState: state,
            hasLiveRuntime: hasLiveRuntime(forPaneId: paneId)
        )
    }

    func loadCredentials(for server: Server) async -> TerminalCredentialLoadResult {
        do {
            return .loaded(try await credentialsProvider(server))
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private func canRunPaneCredentialLoad(paneId: UUID, server: Server) -> Bool {
        guard !Task.isCancelled else { return false }
        return paneStates[paneId]?.serverId == server.id
    }

    @discardableResult
    func requestPaneCredentialLoad(
        paneId: UUID,
        server: Server,
        onCompleted: @escaping @MainActor (TerminalCredentialLoadResult) -> Void = { _ in }
    ) -> UUID {
        if let requestID = paneCredentialLoadRequestByPane[paneId] {
            paneCredentialLoadRequests[requestID]?.onCompleted.append(onCompleted)
            return requestID
        }

        let requestID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.paneCredentialLoadRequests.removeValue(forKey: requestID)
                if self.paneCredentialLoadRequestByPane[paneId] == requestID {
                    self.paneCredentialLoadRequestByPane.removeValue(forKey: paneId)
                }
            }

            guard self.canRunPaneCredentialLoad(paneId: paneId, server: server) else { return }
            let result = await self.loadCredentials(for: server)
            guard self.canRunPaneCredentialLoad(paneId: paneId, server: server) else { return }

            let callbacks = self.paneCredentialLoadRequests[requestID]?.onCompleted ?? []
            callbacks.forEach { $0(result) }
        }
        paneCredentialLoadRequests[requestID] = PaneCredentialLoadRequest(
            paneId: paneId,
            task: task,
            onCompleted: [onCompleted]
        )
        paneCredentialLoadRequestByPane[paneId] = requestID
        return requestID
    }

    func waitForPaneCredentialLoadRequest(_ requestID: UUID) async {
        await paneCredentialLoadRequests[requestID]?.task.value
    }

    func retrustHostAndReconnect(paneId: UUID, server: Server) async -> Bool {
        guard canRunPaneHostRetrust(paneId: paneId, server: server) else { return false }
        await KnownHostsStore.shared.remove(host: server.host, port: server.port)
        guard canRunPaneHostRetrust(paneId: paneId, server: server) else { return false }
        await reconnectPane(paneId)
        return true
    }

    private func canRunPaneHostRetrust(paneId: UUID, server: Server) -> Bool {
        guard !Task.isCancelled else { return false }
        return paneStates[paneId]?.serverId == server.id
    }

    @discardableResult
    func requestPaneHostRetrust(
        paneId: UUID,
        server: Server,
        onCompleted: @escaping @MainActor (Bool) -> Void = { _ in }
    ) -> UUID {
        if let requestID = paneHostRetrustRequestByPane[paneId] {
            paneHostRetrustRequests[requestID]?.onCompleted.append(onCompleted)
            return requestID
        }

        let requestID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.paneHostRetrustRequests.removeValue(forKey: requestID)
                if self.paneHostRetrustRequestByPane[paneId] == requestID {
                    self.paneHostRetrustRequestByPane.removeValue(forKey: paneId)
                }
            }

            guard self.canRunPaneHostRetrust(paneId: paneId, server: server) else {
                let callbacks = self.paneHostRetrustRequests[requestID]?.onCompleted ?? []
                callbacks.forEach { $0(false) }
                return
            }

            #if DEBUG
            let didReconnect: Bool
            if let operation = self.paneHostRetrustOperationForTesting {
                didReconnect = await operation(paneId, server)
            } else {
                didReconnect = await self.retrustHostAndReconnect(paneId: paneId, server: server)
            }
            #else
            let didReconnect = await self.retrustHostAndReconnect(paneId: paneId, server: server)
            #endif

            let callbacks = self.paneHostRetrustRequests[requestID]?.onCompleted ?? []
            callbacks.forEach {
                $0(self.canRunPaneHostRetrust(paneId: paneId, server: server) ? didReconnect : false)
            }
        }
        paneHostRetrustRequests[requestID] = PaneHostRetrustRequest(
            paneId: paneId,
            task: task,
            onCompleted: [onCompleted]
        )
        paneHostRetrustRequestByPane[paneId] = requestID
        return requestID
    }

    func waitForPaneHostRetrustRequest(_ requestID: UUID) async {
        await paneHostRetrustRequests[requestID]?.task.value
    }

    func installMoshServerAndReconnect(for paneId: UUID) async throws {
        try await installMoshServer(for: paneId)
        await reconnectPane(paneId)
    }

    @discardableResult
    func requestTmuxInstall(
        for paneId: UUID,
        onCompleted: @escaping @MainActor () -> Void = {}
    ) -> UUID {
        if let requestID = tmuxInstallRequestByPane[paneId] {
            tmuxInstallRequests[requestID]?.onCompleted.append(onCompleted)
            return requestID
        }

        let requestID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.tmuxInstallRequests.removeValue(forKey: requestID)
                if self.tmuxInstallRequestByPane[paneId] == requestID {
                    self.tmuxInstallRequestByPane.removeValue(forKey: paneId)
                }
            }

            #if DEBUG
            if let operation = self.tmuxInstallOperationForTesting {
                await operation(paneId)
            } else {
                await self.startTmuxInstall(for: paneId)
            }
            #else
            await self.startTmuxInstall(for: paneId)
            #endif

            guard !Task.isCancelled else { return }
            let callbacks = self.tmuxInstallRequests[requestID]?.onCompleted ?? []
            callbacks.forEach { $0() }
        }
        tmuxInstallRequests[requestID] = TmuxInstallRequest(
            paneId: paneId,
            task: task,
            onCompleted: [onCompleted]
        )
        tmuxInstallRequestByPane[paneId] = requestID
        return requestID
    }

    func waitForTmuxInstallRequest(_ requestID: UUID) async {
        await tmuxInstallRequests[requestID]?.task.value
    }

    @discardableResult
    func requestMoshInstallAndReconnect(
        for paneId: UUID,
        onCompleted: @escaping @MainActor () -> Void = {},
        onFailed: @escaping @MainActor (Error) -> Void = { _ in }
    ) -> UUID {
        if let requestID = moshInstallRequestByPane[paneId] {
            moshInstallRequests[requestID]?.onCompleted.append(onCompleted)
            moshInstallRequests[requestID]?.onFailed.append(onFailed)
            return requestID
        }

        lastMoshInstallFailure = nil
        let requestID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.moshInstallRequests.removeValue(forKey: requestID)
                if self.moshInstallRequestByPane[paneId] == requestID {
                    self.moshInstallRequestByPane.removeValue(forKey: paneId)
                }
            }

            do {
                #if DEBUG
                if let operation = self.moshInstallAndReconnectOperationForTesting {
                    try await operation(paneId)
                } else {
                    try await self.installMoshServerAndReconnect(for: paneId)
                }
                #else
                try await self.installMoshServerAndReconnect(for: paneId)
                #endif

                guard !Task.isCancelled else { return }
                let callbacks = self.moshInstallRequests[requestID]?.onCompleted ?? []
                callbacks.forEach { $0() }
            } catch is CancellationError {
                let callbacks = self.moshInstallRequests[requestID]?.onCompleted ?? []
                callbacks.forEach { $0() }
                return
            } catch {
                self.lastMoshInstallFailure = error
                let callbacks = self.moshInstallRequests[requestID]?.onFailed ?? []
                callbacks.forEach { $0(error) }
            }
        }
        moshInstallRequests[requestID] = MoshInstallRequest(
            paneId: paneId,
            task: task,
            onCompleted: [onCompleted],
            onFailed: [onFailed]
        )
        moshInstallRequestByPane[paneId] = requestID
        return requestID
    }

    func waitForMoshInstallRequest(_ requestID: UUID) async {
        await moshInstallRequests[requestID]?.task.value
    }

    func handlePaneExit(for paneId: UUID) async {
        guard paneStates[paneId] != nil else { return }
        updatePaneState(paneId, connectionState: .disconnected)
        await unregisterSSHClient(for: paneId)
    }

    @discardableResult
    func requestPaneProcessExit(forPane paneId: UUID) -> UUID? {
        guard paneStates[paneId] != nil else { return nil }

        if let existingRequestID = processExitRequestByPane[paneId],
           processExitRequests[existingRequestID] != nil {
            return existingRequestID
        }

        let requestID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.processExitRequests.removeValue(forKey: requestID)
                if self.processExitRequestByPane[paneId] == requestID {
                    self.processExitRequestByPane.removeValue(forKey: paneId)
                }
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

        processExitRequests[requestID] = ProcessExitRequest(paneId: paneId, task: task)
        processExitRequestByPane[paneId] = requestID
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
        connectWatchdogTasks[paneId]?.cancel()
        connectWatchdogTasks[paneId] = nil

        guard shouldScheduleConnectWatchdog(
            forPaneId: paneId,
            isReady: isReady,
            terminalExists: terminalExists
        ) else {
            connectWatchdogGenerations.removeValue(forKey: paneId)
            return
        }

        let generation = UUID()
        connectWatchdogGenerations[paneId] = generation
        let task = Task { @MainActor [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            guard let self else { return }
            guard self.connectWatchdogGenerations[paneId] == generation else { return }

            let action = self.handleConnectWatchdogTimeout(
                forPaneId: paneId,
                isReady: isReady,
                terminalExists: terminalExists,
                timeoutMessage: timeoutMessage
            )

            switch action {
            case .retry:
                self.connectWatchdogTasks[paneId] = nil
                self.connectWatchdogGenerations.removeValue(forKey: paneId)
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
                self.connectWatchdogTasks[paneId] = nil
                self.connectWatchdogGenerations.removeValue(forKey: paneId)
            }
        }
        connectWatchdogTasks[paneId] = task
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

    /// Remove pane UI/runtime state and return the SSH teardown that must be awaited.
    private func preparePaneClose(_ paneId: UUID) -> PaneCloseResult {
        let serverId = paneStates[paneId]?.serverId
        let tmuxSessionToKill = paneTmuxStatus(for: paneId)
            .flatMap { managedTmuxSessionNameToKill(for: paneId, status: $0) }

        if let serverId {
            terminalConnectionRegistry.updateState(
                .disconnected,
                for: .pane(paneId),
                serverId: serverId
            )
        }
        cancelInstallRequests(for: paneId)
        cancelPaneRetryRequest(for: paneId)
        cancelPaneHostRetrustRequest(for: paneId)
        cancelPaneCredentialLoadRequest(for: paneId)
        cancelInputRequests(for: paneId)
        let richPasteUploadTasks = cancelPaneRichPasteUploadRequests(for: paneId)
        cancelResizeRequests(for: paneId)
        cancelProcessExitRequests(for: paneId)
        clearTmuxRuntimeState(for: paneId)
        unregisterTerminal(for: paneId)
        paneStates.removeValue(forKey: paneId)
        runtimeTitleByPane.removeValue(forKey: paneId)

        return PaneCloseResult(
            paneId: paneId,
            tmuxSessionNameToKill: tmuxSessionToKill,
            richPasteUploadTasks: richPasteUploadTasks
        )
    }

    private func cancelInstallRequests(for paneId: UUID) {
        if let requestID = tmuxInstallRequestByPane.removeValue(forKey: paneId),
           let request = tmuxInstallRequests.removeValue(forKey: requestID) {
            request.task.cancel()
            request.onCompleted.forEach { $0() }
        }

        if let requestID = moshInstallRequestByPane.removeValue(forKey: paneId),
           let request = moshInstallRequests.removeValue(forKey: requestID) {
            request.task.cancel()
            request.onCompleted.forEach { $0() }
        }
    }

    private func cancelInputRequests(for paneId: UUID) {
        let requestIDs = inputRequests.compactMap { requestID, request in
            request.paneId == paneId ? requestID : nil
        }

        for requestID in requestIDs {
            inputRequests.removeValue(forKey: requestID)?.task.cancel()
        }

        inputRequestByPane.removeValue(forKey: paneId)
        lastInputTaskByPane.removeValue(forKey: paneId)
    }

    private func cancelPaneRichPasteUploadRequests(for paneId: UUID) -> [Task<Void, Never>] {
        let requestIDs = richPasteUploadRequests.compactMap { requestID, request in
            request.paneId == paneId ? requestID : nil
        }

        var tasks: [Task<Void, Never>] = []
        for requestID in requestIDs {
            if let task = richPasteUploadRequests[requestID]?.task {
                task.cancel()
                tasks.append(task)
            }
        }

        richPasteUploadRequestByPane.removeValue(forKey: paneId)
        return tasks
    }

    private func cancelResizeRequests(for paneId: UUID) {
        let requestIDs = resizeRequests.compactMap { requestID, request in
            request.paneId == paneId ? requestID : nil
        }

        for requestID in requestIDs {
            resizeRequests.removeValue(forKey: requestID)?.task.cancel()
        }

        resizeRequestByPane.removeValue(forKey: paneId)
    }

    private func cancelProcessExitRequests(for paneId: UUID) {
        let requestIDs = processExitRequests.compactMap { requestID, request in
            request.paneId == paneId ? requestID : nil
        }

        for requestID in requestIDs {
            processExitRequests.removeValue(forKey: requestID)?.task.cancel()
        }

        processExitRequestByPane.removeValue(forKey: paneId)
    }

    private func cancelPaneRetryRequest(for paneId: UUID) {
        if let requestID = paneRetryRequestByPane.removeValue(forKey: paneId),
           let request = paneRetryRequests.removeValue(forKey: requestID) {
            request.task.cancel()
            request.onCompleted.forEach { $0(.skipped) }
        }
    }

    private func cancelPaneHostRetrustRequest(for paneId: UUID) {
        if let requestID = paneHostRetrustRequestByPane.removeValue(forKey: paneId),
           let request = paneHostRetrustRequests.removeValue(forKey: requestID) {
            request.task.cancel()
            request.onCompleted.forEach { $0(false) }
        }
    }

    private func cancelPaneCredentialLoadRequest(for paneId: UUID) {
        guard let requestID = paneCredentialLoadRequestByPane.removeValue(forKey: paneId) else { return }
        paneCredentialLoadRequests[requestID]?.task.cancel()
    }

    private func finishTabClose(_ closeResult: TabCloseResult) async {
        for paneCloseResult in closeResult.paneCloseResults {
            await finishPaneClose(paneCloseResult)
        }
    }

    private func finishPaneClose(_ closeResult: PaneCloseResult) async {
        for task in closeResult.richPasteUploadTasks {
            await task.value
        }

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

    private func waitForAllServerTeardownTasks() async {
        while !serverTeardownTasks.isEmpty {
            for serverId in Array(serverTeardownTasks.keys) {
                await waitForServerTeardownTasks(serverId)
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

    private func trackShellCleanup(
        for serverId: UUID,
        reason: String,
        priority: TaskPriority = .utility,
        operation: @escaping @Sendable () async -> Void
    ) {
#if DEBUG
        let testingOperation = rejectedShellCleanupOperationForTesting
#endif
        let task = Task.detached(priority: priority) { [logger] in
            logger.info("Pane shell cleanup started [serverId: \(serverId.uuidString, privacy: .public), reason: \(reason, privacy: .public)]")
#if DEBUG
            if let testingOperation {
                await testingOperation()
            } else {
                await operation()
            }
#else
            await operation()
#endif
            logger.info("Pane shell cleanup finished [serverId: \(serverId.uuidString, privacy: .public), reason: \(reason, privacy: .public)]")
        }
        trackServerTeardownTask(task, for: serverId)
    }

    private func trackTmuxKill(
        for serverId: UUID,
        sessionName: String,
        client: SSHClient,
        preferred: TerminalMultiplexer
    ) {
#if DEBUG
        let testingOperation = tmuxKillOperationForTesting
#endif
        let task = Task.detached(priority: .utility) { [logger] in
            logger.info("Managed pane tmux kill started [serverId: \(serverId.uuidString, privacy: .public), sessionName: \(sessionName, privacy: .public)]")
#if DEBUG
            if let testingOperation {
                await testingOperation()
            } else {
                await RemoteTmuxManager.shared.killSession(named: sessionName, using: client, preferred: preferred)
            }
#else
            await RemoteTmuxManager.shared.killSession(named: sessionName, using: client, preferred: preferred)
#endif
            logger.info("Managed pane tmux kill finished [serverId: \(serverId.uuidString, privacy: .public), sessionName: \(sessionName, privacy: .public)]")
        }
        trackServerTeardownTask(task, for: serverId)
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

        for _ in 0..<6 {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            let available = await RemoteTmuxManager.shared.isTmuxAvailable(using: registration.client, preferred: preferred)
            if available {
                tmuxResolver.bindManagedSession(for: paneId, serverId: serverId)
                updatePaneTmuxStatus(paneId, status: currentTmuxStatus(for: paneId, serverId: serverId))
                return
            }
        }
        updatePaneTmuxStatus(paneId, status: tmuxResolver.unavailableStatus(for: serverId))
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
        trackTmuxKill(
            for: registration.serverId,
            sessionName: sessionName,
            client: registration.client,
            preferred: preferred
        )
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
        successfulConnectionRecorder = { EngagementTracker.shared.recordSuccessfulConnection(id: $0, transport: $1) }
        tabsByServer = [:]
        selectedTabByServer = [:]
        selectedViewByServer = [:]
        paneStates = [:]
        tmuxAttachPrompt = nil
        terminalRegistryVersion = 0
        shellRegistry.removeAll()
        tabOpensInFlight.removeAll()
        tabOpenRequests.values.forEach { $0.cancel() }
        tabOpenRequests.removeAll()
        lastTabOpenFailure = nil
        tmuxInstallRequests.values.forEach { $0.task.cancel() }
        tmuxInstallRequests.removeAll()
        tmuxInstallRequestByPane.removeAll()
        moshInstallRequests.values.forEach { $0.task.cancel() }
        moshInstallRequests.removeAll()
        moshInstallRequestByPane.removeAll()
        lastMoshInstallFailure = nil
        paneRetryRequests.values.forEach { $0.task.cancel() }
        paneRetryRequests.removeAll()
        paneRetryRequestByPane.removeAll()
        paneHostRetrustRequests.values.forEach { $0.task.cancel() }
        paneHostRetrustRequests.removeAll()
        paneHostRetrustRequestByPane.removeAll()
        paneCredentialLoadRequests.values.forEach { $0.task.cancel() }
        paneCredentialLoadRequests.removeAll()
        paneCredentialLoadRequestByPane.removeAll()
        surfaceAttachRequests.values.forEach { $0.task.cancel() }
        surfaceAttachRequests.removeAll()
        surfaceAttachRequestByPane.removeAll()
        inputRequests.values.forEach { $0.task.cancel() }
        inputRequests.removeAll()
        inputRequestByPane.removeAll()
        lastInputTaskByPane.removeAll()
        let richPasteUploadTasks = richPasteUploadRequests.values.map(\.task)
        richPasteUploadTasks.forEach { $0.cancel() }
        for task in richPasteUploadTasks {
            await task.value
        }
        richPasteUploadRequests.removeAll()
        richPasteUploadRequestByPane.removeAll()
        resizeRequests.values.forEach { $0.task.cancel() }
        resizeRequests.removeAll()
        resizeRequestByPane.removeAll()
        processExitRequests.values.forEach { $0.task.cancel() }
        processExitRequests.removeAll()
        processExitRequestByPane.removeAll()
        paneReconnectsInFlight.removeAll()
        connectWatchdogTasks.values.forEach { $0.cancel() }
        connectWatchdogTasks.removeAll()
        connectWatchdogGenerations.removeAll()
        credentialsProvider = { server in
            try KeychainManager.shared.getCredentials(for: server)
        }
        serverUnlocker = { server in
            await AppLockManager.shared.ensureServerUnlocked(server)
        }
        serverTeardownTasks.removeAll()
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
