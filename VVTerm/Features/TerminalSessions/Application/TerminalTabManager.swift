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
import Combine
import os.log

@MainActor
final class TerminalTabManager: ObservableObject {
    static let shared = TerminalTabManager()

    typealias PaneCloseResult = TerminalTabManagerSupport.PaneCloseResult
    typealias TabCloseResult = TerminalTabManagerSupport.TabCloseResult
    typealias TmuxInstallRequest = TerminalTabManagerSupport.TmuxInstallRequest
    typealias TmuxLifecycleRequest = TerminalTabManagerSupport.TmuxLifecycleRequest
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
    typealias ServerProvider = @MainActor (UUID) -> Server?
    typealias IsProProvider = @MainActor () -> Bool
    typealias DefaultViewProvider = @MainActor () -> String
    typealias ServerUnlocker = @MainActor (Server) async -> Bool
    typealias CredentialsProvider = @MainActor (Server) async throws -> ServerCredentials
    typealias KnownHostTrustApprover = @MainActor (_ host: String, _ port: Int) async -> Void
    typealias SuccessfulConnectionRecorder = @MainActor (_ id: UUID, _ transport: String) -> Void
    typealias SplitPaneCreatedTracker = @MainActor () -> Void
    typealias TerminalSessionEndRecorder = @MainActor (_ otherTerminalsActive: Bool, _ isPro: Bool) -> Void
    typealias VoiceInputCanceller = @MainActor (TerminalVoiceInputTarget) -> Task<Void, Never>

    struct Dependencies {
        var isProProvider: IsProProvider
        var defaultViewProvider: DefaultViewProvider
        var serverUnlocker: ServerUnlocker
        var serverProvider: ServerProvider
        var credentialsProvider: CredentialsProvider
        var tmuxService: any TerminalTmuxServicing
        var tmuxPreferences: any TmuxAttachPreferenceProviding
        var moshService: any TerminalMoshServicing
        var knownHostTrustApprover: KnownHostTrustApprover
        var workingDirectoryService: any TerminalWorkingDirectoryApplying
        var successfulConnectionRecorder: SuccessfulConnectionRecorder
        var splitPaneCreatedTracker: SplitPaneCreatedTracker
        var terminalSessionEndRecorder: TerminalSessionEndRecorder
        var voiceInputCanceller: VoiceInputCanceller
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
    var tabOpenRequestStore = TerminalOpenRequestStore()
    var lastTabOpenFailure: Error?
    var pendingTabOpenRequestIDs: Set<UUID> { tabOpenRequestStore.pendingRequestIDs }
    var tmuxInstallRequestStore = TerminalScopedRequestStore<TmuxInstallRequest>()
    var pendingTmuxInstallRequestIDs: Set<UUID> { tmuxInstallRequestStore.pendingRequestIDs }
    var tmuxLifecycleRequestStore = TerminalScopedRequestStore<TmuxLifecycleRequest>()
    var pendingTmuxLifecycleRequestIDs: Set<UUID> { tmuxLifecycleRequestStore.pendingRequestIDs }
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
    private var dependencies: Dependencies {
        didSet {
            tmuxResolver.setServerProvider(dependencies.serverProvider)
            tmuxResolver.setTmuxService(dependencies.tmuxService)
            tmuxResolver.setPreferences(dependencies.tmuxPreferences)
        }
    }

    var isProProvider: IsProProvider {
        get { dependencies.isProProvider }
        set { updateDependencies { $0.isProProvider = newValue } }
    }
    var defaultViewProvider: DefaultViewProvider {
        get { dependencies.defaultViewProvider }
        set { updateDependencies { $0.defaultViewProvider = newValue } }
    }
    var serverUnlocker: ServerUnlocker {
        get { dependencies.serverUnlocker }
        set { updateDependencies { $0.serverUnlocker = newValue } }
    }
    var reconnectInFlightStore = TerminalReconnectInFlightStore()
    /// In-flight SSH teardown tasks by server, used to serialize close/open ordering.
    var serverTeardownTaskStore = TerminalTeardownTaskStore()
    /// Application-owned connect watchdog timers keyed by pane.
    var connectWatchdogStore = TerminalConnectWatchdogStore()
    var serverProvider: ServerProvider {
        get { dependencies.serverProvider }
        set { updateDependencies { $0.serverProvider = newValue } }
    }
    var credentialsProvider: CredentialsProvider {
        get { dependencies.credentialsProvider }
        set { updateDependencies { $0.credentialsProvider = newValue } }
    }
    var tmuxService: any TerminalTmuxServicing {
        get { dependencies.tmuxService }
        set { updateDependencies { $0.tmuxService = newValue } }
    }
    var tmuxPreferences: any TmuxAttachPreferenceProviding {
        get { dependencies.tmuxPreferences }
        set { updateDependencies { $0.tmuxPreferences = newValue } }
    }
    var moshService: any TerminalMoshServicing {
        get { dependencies.moshService }
        set { updateDependencies { $0.moshService = newValue } }
    }
    var knownHostTrustApprover: KnownHostTrustApprover {
        get { dependencies.knownHostTrustApprover }
        set { updateDependencies { $0.knownHostTrustApprover = newValue } }
    }
    var workingDirectoryService: any TerminalWorkingDirectoryApplying {
        get { dependencies.workingDirectoryService }
        set { updateDependencies { $0.workingDirectoryService = newValue } }
    }
    var successfulConnectionRecorder: SuccessfulConnectionRecorder {
        get { dependencies.successfulConnectionRecorder }
        set { updateDependencies { $0.successfulConnectionRecorder = newValue } }
    }
    var splitPaneCreatedTracker: SplitPaneCreatedTracker {
        get { dependencies.splitPaneCreatedTracker }
        set { updateDependencies { $0.splitPaneCreatedTracker = newValue } }
    }
    var terminalSessionEndRecorder: TerminalSessionEndRecorder {
        get { dependencies.terminalSessionEndRecorder }
        set { updateDependencies { $0.terminalSessionEndRecorder = newValue } }
    }
    var voiceInputCanceller: VoiceInputCanceller {
        get { dependencies.voiceInputCanceller }
        set { updateDependencies { $0.voiceInputCanceller = newValue } }
    }
    /// Application-owned pane SSH runtimes. SwiftUI coordinators attach surfaces and send intent only.
    var paneRuntimes: [UUID: PaneRuntimeState] = [:]
    let terminalConnectionRegistry = TerminalConnectionRegistry()
    #if DEBUG
    var testingTerminalConnectionClientFactory: (@MainActor (TerminalEntityID, Server?) -> any TerminalConnectionClient)?
    var rejectedShellCleanupOperationForTesting: (@MainActor @Sendable () async -> Void)?
    var tmuxKillOperationForTesting: (@MainActor @Sendable () async -> Void)?
    var tmuxInstallOperationForTesting: (@MainActor (UUID) async -> Void)?
    var tmuxLifecycleOperationForTesting: (@MainActor (UUID, UUID, UUID) async -> Void)?
    var moshInstallAndReconnectOperationForTesting: (@MainActor (UUID) async throws -> Void)?
    var paneRetryOperationForTesting: (@MainActor (UUID, Server) async -> TerminalReconnectRequestResult)?
    var paneHostRetrustOperationForTesting: (@MainActor (UUID, Server) async -> Bool)?
    var surfaceAttachOperationForTesting: (@MainActor (TerminalEntityID) async -> Void)?
    var inputOperationForTesting: (@MainActor (Data, TerminalEntityID) async -> Void)?
    var richPasteLeaseProviderForTesting: (@MainActor (UUID) -> RemoteConnectionLease?)?
    var richPasteUploadOperationForTesting: TerminalRichPasteUploadOperation?
    var resizeOperationForTesting: (@MainActor (TerminalResizeRequestSize, TerminalEntityID) async -> Void)?
    var processExitOperationForTesting: (@MainActor (TerminalEntityID) async -> Void)?
    #endif

    /// Pane state keyed by pane ID
    @Published var paneStates: [UUID: TerminalPaneState] = [:]
    @Published var runtimeTitleByPane: [UUID: String] = [:]

    @Published var tmuxAttachPrompt: TmuxAttachPrompt?

    let tmuxResolver: TmuxAttachResolver

    /// Bumps when a terminal view is registered/unregistered so views refresh.
    @Published var terminalRegistryVersion: Int = 0

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
        let dependencies = Dependencies.live
        self.dependencies = dependencies
        tmuxResolver = TmuxAttachResolver(
            serverProvider: dependencies.serverProvider,
            tmuxService: dependencies.tmuxService,
            preferences: dependencies.tmuxPreferences
        )
        restoreSnapshot()
    }

    private func updateDependencies(_ update: (inout Dependencies) -> Void) {
        var updated = dependencies
        update(&updated)
        dependencies = updated
    }

    func restoreLiveDependencies() {
        dependencies = .live
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

    func setPaneTransport(
        _ transport: ShellTransport,
        fallbackReason: MoshFallbackReason?,
        for paneId: UUID
    ) {
        paneStates[paneId]?.activeTransport = transport
        paneStates[paneId]?.moshFallbackReason = fallbackReason
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
        if isProProvider() { return true }
        let totalTabs = tabsByServer.values.flatMap { $0 }.count
        return totalTabs < FreeTierLimits.maxTabs
    }

    func waitForSurfaceAttachRequest(_ requestID: UUID) async {
        await surfaceAttachRequestStore[requestID]?.task.value
    }

    func waitForProcessExitRequest(_ requestID: UUID) async {
        await processExitRequestStore[requestID]?.task.value
    }

    // MARK: - Split Management

    /// Split a pane horizontally (left | right)
    func splitHorizontal(tab: TerminalTab, paneId: UUID) -> UUID? {
        guard isProProvider() else { return nil }
        let newPaneId = splitPane(tab: tab, paneId: paneId, direction: .horizontal)
        if newPaneId != nil {
            splitPaneCreatedTracker()
        }
        return newPaneId
    }

    /// Split a pane vertically (top / bottom)
    func splitVertical(tab: TerminalTab, paneId: UUID) -> UUID? {
        guard isProProvider() else { return nil }
        let newPaneId = splitPane(tab: tab, paneId: paneId, direction: .vertical)
        if newPaneId != nil {
            splitPaneCreatedTracker()
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
