import Foundation
import Combine
import os.log
#if os(macOS)
import AppKit
#endif
#if os(iOS)
import UIKit
#endif

@MainActor
final class ConnectionSessionManager: ObservableObject {
    static let shared = ConnectionSessionManager()

    typealias SSHUnregisterResult = ConnectionSessionManagerSupport.SSHUnregisterResult
    typealias SessionCloseResult = ConnectionSessionManagerSupport.SessionCloseResult
    typealias ShellTeardownRequest = ConnectionSessionManagerSupport.ShellTeardownRequest
    typealias TmuxInstallRequest = ConnectionSessionManagerSupport.TmuxInstallRequest
    typealias MoshInstallRequest = ConnectionSessionManagerSupport.MoshInstallRequest
    typealias SessionRetryRequest = ConnectionSessionManagerSupport.SessionRetryRequest
    typealias ActiveConnectionOpenRequest = ConnectionSessionManagerSupport.ActiveConnectionOpenRequest
    typealias ForegroundReconnectRequest = ConnectionSessionManagerSupport.ForegroundReconnectRequest
    typealias ForegroundReconnectCallback = ConnectionSessionManagerSupport.ForegroundReconnectCallback
    typealias SessionHostRetrustRequest = ConnectionSessionManagerSupport.SessionHostRetrustRequest
    typealias SessionCredentialLoadRequest = ConnectionSessionManagerSupport.SessionCredentialLoadRequest
    typealias SurfaceAttachRequest = ConnectionSessionManagerSupport.SurfaceAttachRequest
    typealias InputRequest = ConnectionSessionManagerSupport.InputRequest
    typealias RichPasteUploadRequest = ConnectionSessionManagerSupport.RichPasteUploadRequest
    typealias ResizeRequest = ConnectionSessionManagerSupport.ResizeRequest
    typealias ProcessExitRequest = ConnectionSessionManagerSupport.ProcessExitRequest
    typealias SessionRuntimeState = ConnectionSessionManagerSupport.SessionRuntimeState

    @Published var sessions: [ConnectionSession] = [] {
        didSet {
            liveActivityRefresh(liveActivitySnapshots)
            schedulePersist()
        }
    }
    var liveActivityRefresh: @MainActor ([TerminalLiveActivitySnapshot]) -> Void = {
        LiveActivityManager.shared.refresh(with: $0)
    }
    var successfulConnectionRecorder: @MainActor (_ id: UUID, _ transport: String) -> Void = {
        EngagementTracker.shared.recordSuccessfulConnection(id: $0, transport: $1)
    }
    @Published var selectedSessionId: UUID? {
        didSet {
            schedulePersist()
            if let selectedSessionId,
               let session = sessions.first(where: { $0.id == selectedSessionId }) {
                selectedSessionByServer[session.serverId] = selectedSessionId
            }
            updateTmuxSelectionStatuses()
        }
    }

    /// Legacy alias for servers with live terminal transports. Open-but-restored sessions are tracked by `openServerIds`.
    var connectedServerIds: Set<UUID> {
        activeServerIds
    }

    /// Per-server view state (stats/terminal) - persists when switching servers
    @Published var selectedViewByServer: [UUID: String] = [:] {
        didSet { schedulePersist() }
    }

    /// Per-server selected terminal tab - persists when switching servers
    @Published var selectedSessionByServer: [UUID: UUID] = [:] {
        didSet { schedulePersist() }
    }

    @Published var tmuxAttachPrompt: TmuxAttachPrompt?
    @Published var terminalBrowseModeBySession: [UUID: Bool] = [:]
    @Published var terminalFindNavigatorVisibleBySession: [UUID: Bool] = [:]
    @Published private(set) var runtimeTitleBySession: [UUID: String] = [:]

    let tmuxResolver = TmuxAttachResolver()

    /// Legacy single server ID for backward compatibility
    var connectedServerId: UUID? {
        connectedServerIds.first
    }

    var openServerIds: Set<UUID> {
        Set(sessions.map(\.serverId))
    }

    var activeServerIds: Set<UUID> {
        terminalConnectionRegistry.activeServerIds
    }

    func hasLiveRuntime(forSessionId sessionId: UUID) -> Bool {
        terminalConnectionRegistry.isOpeningOrStreaming(.session(sessionId))
    }

    func shouldAutoReconnectSession(
        _ sessionId: UUID,
        isSceneActive: Bool,
        autoReconnectEnabled: Bool,
        reconnectInFlight: Bool = false
    ) -> Bool {
        guard let state = sessionState(for: sessionId) else { return false }
        return TerminalAutoReconnectPolicy.shouldAttemptReconnect(
            isSceneActive: isSceneActive,
            autoReconnectEnabled: autoReconnectEnabled,
            reconnectInFlight: reconnectInFlight || reconnectInFlightStore.contains(sessionId),
            isSuspendingForBackground: isSuspendingForBackground,
            connectionState: state,
            hasLiveRuntime: hasLiveRuntime(forSessionId: sessionId)
        )
    }

    func shouldManuallyReconnectSession(
        _ sessionId: UUID,
        reconnectInFlight: Bool
    ) -> Bool {
        guard let state = sessionState(for: sessionId) else { return false }
        return TerminalManualReconnectPolicy.shouldAttemptReconnect(
            reconnectInFlight: reconnectInFlight || reconnectInFlightStore.contains(sessionId),
            snapshotState: state,
            hasLiveRuntime: hasLiveRuntime(forSessionId: sessionId)
        )
    }

    func foregroundReconnectActionForSelectedSession(
        selectedViewId: String,
        terminalViewId: String,
        refreshTerminal: Bool,
        autoReconnectEnabled: Bool
    ) -> TerminalForegroundReconnectAction? {
        guard let sessionId = selectedSessionId,
              sessionWithID(sessionId) != nil else {
            return nil
        }
        return TerminalForegroundReconnectPolicy.action(
            selectedViewId: selectedViewId,
            terminalViewId: terminalViewId,
            selectedSessionId: sessionId,
            selectedSessionHasLiveRuntime: hasLiveRuntime(forSessionId: sessionId),
            refreshTerminal: refreshTerminal,
            autoReconnectEnabled: autoReconnectEnabled,
            isSuspendingForBackground: isSuspendingForBackground
        )
    }

    func handleForegroundReconnectForSelectedSession(
        selectedViewId: String,
        terminalViewId: String,
        refreshTerminal: Bool,
        autoReconnectEnabled: Bool
    ) async -> TerminalForegroundReconnectAction? {
        guard let action = foregroundReconnectActionForSelectedSession(
            selectedViewId: selectedViewId,
            terminalViewId: terminalViewId,
            refreshTerminal: refreshTerminal,
            autoReconnectEnabled: autoReconnectEnabled
        ) else {
            return nil
        }

        if action.shouldReconnect,
           let session = sessionWithID(action.sessionId) {
            _ = await reconnectSessionIfRuntimeInactive(session)
        }

        return action
    }

    let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "ConnectionSession")
    var shellRegistry = SSHShellRegistry(staleThreshold: 120)

    /// Terminal UI surfaces indexed by session entity. SSH runtime ownership is separate.
    let terminalSurfaceRegistry = TerminalSurfaceRegistry()
    /// Sessions whose preserved terminal must be reset before attaching a fresh shell.
    var terminalsNeedingReconnectReset: Set<UUID> = []

    /// Shell lifecycle handlers indexed by session ID.
    var shellHandlerStore = TerminalShellHandlerStore()
    /// Server IDs and request tasks with an in-flight open request, used to collapse repeated clicks.
    var connectionOpenRequestStore = TerminalOpenRequestStore()
    var lastConnectionOpenFailure: Error?
    var pendingConnectionOpenRequestIDs: Set<UUID> { connectionOpenRequestStore.pendingRequestIDs }
    var tmuxInstallRequestStore = TerminalScopedRequestStore<TmuxInstallRequest>()
    var pendingTmuxInstallRequestIDs: Set<UUID> { tmuxInstallRequestStore.pendingRequestIDs }
    var moshInstallRequestStore = TerminalScopedRequestStore<MoshInstallRequest>()
    private(set) var lastMoshInstallFailure: Error?
    var pendingMoshInstallRequestIDs: Set<UUID> { moshInstallRequestStore.pendingRequestIDs }
    var sessionRetryRequestStore = TerminalScopedRequestStore<SessionRetryRequest>()
    var pendingSessionRetryRequestIDs: Set<UUID> { sessionRetryRequestStore.pendingRequestIDs }
    var activeConnectionOpenRequestStore = TerminalScopedRequestStore<ActiveConnectionOpenRequest>()
    var pendingActiveConnectionOpenRequestIDs: Set<UUID> { activeConnectionOpenRequestStore.pendingScopedRequestIDs }
    var foregroundReconnectRequestStore = TerminalScopedRequestStore<ForegroundReconnectRequest>()
    var pendingForegroundReconnectRequestIDs: Set<UUID> { foregroundReconnectRequestStore.pendingScopedRequestIDs }
    var sessionHostRetrustRequestStore = TerminalScopedRequestStore<SessionHostRetrustRequest>()
    var pendingSessionHostRetrustRequestIDs: Set<UUID> { sessionHostRetrustRequestStore.pendingRequestIDs }
    var sessionCredentialLoadRequestStore = TerminalScopedRequestStore<SessionCredentialLoadRequest>()
    var pendingSessionCredentialLoadRequestIDs: Set<UUID> { sessionCredentialLoadRequestStore.pendingScopedRequestIDs }
    var surfaceAttachRequestStore = TerminalScopedRequestStore<SurfaceAttachRequest>()
    var pendingSurfaceAttachRequestIDs: Set<UUID> { surfaceAttachRequestStore.pendingRequestIDs }
    var inputRequestStore = TerminalSerialRequestStore<InputRequest>()
    var pendingInputRequestIDs: Set<UUID> { inputRequestStore.pendingRequestIDs }
    var richPasteUploadRequestStore = TerminalScopedRequestStore<RichPasteUploadRequest>()
    var pendingSessionRichPasteUploadRequestIDs: Set<UUID> { richPasteUploadRequestStore.pendingRequestIDs }
    var resizeRequestStore = TerminalScopedRequestStore<ResizeRequest>()
    var pendingResizeRequestIDs: Set<UUID> { resizeRequestStore.pendingRequestIDs }
    var processExitRequestStore = TerminalScopedRequestStore<ProcessExitRequest>()
    var pendingProcessExitRequestIDs: Set<UUID> { processExitRequestStore.pendingRequestIDs }
    var reconnectInFlightStore = TerminalReconnectInFlightStore()
    /// Server disconnect cleanups in progress. New opens wait for the matching cleanup.
    var serverDisconnectTaskStore = TerminalServerTaskStore()
    /// Application-owned connect watchdog timers keyed by session.
    var connectWatchdogStore = TerminalConnectWatchdogStore()
    var credentialsProvider: @MainActor (Server) async throws -> ServerCredentials = { server in
        try KeychainManager.shared.getCredentials(for: server)
    }
    /// Per-server teardown work from ordinary tab closes. New opens wait for this too.
    var serverTeardownTaskStore = TerminalTeardownTaskStore()
    /// Application-owned tab SSH runtimes. SwiftUI coordinators attach surfaces and send intent only.
    var sessionRuntimes: [UUID: SessionRuntimeState] = [:]
    let terminalConnectionRegistry = TerminalConnectionRegistry()
    #if DEBUG
    var testingTerminalConnectionClientFactory: (@MainActor (TerminalEntityID, Server?) -> any TerminalConnectionClient)?
    var rejectedShellCleanupOperationForTesting: (@MainActor @Sendable () async -> Void)?
    var tmuxKillOperationForTesting: (@MainActor @Sendable () async -> Void)?
    var tmuxInstallOperationForTesting: (@MainActor (UUID) async -> Void)?
    var moshInstallAndReconnectOperationForTesting: (@MainActor (ConnectionSession) async throws -> Void)?
    var sessionRetryOperationForTesting: (@MainActor (ConnectionSession, Server?) async -> TerminalReconnectRequestResult)?
    var activeConnectionOpenReconnectOperationForTesting: (@MainActor (ConnectionSession) async -> Bool)?
    var foregroundReconnectOperationForTesting: (@MainActor (ConnectionSession) async -> Bool)?
    var sessionHostRetrustOperationForTesting: (@MainActor (ConnectionSession, Server) async -> Bool)?
    var surfaceAttachOperationForTesting: (@MainActor (TerminalEntityID) async -> Void)?
    var inputOperationForTesting: (@MainActor (Data, TerminalEntityID) async -> Void)?
    var richPasteLeaseProviderForTesting: (@MainActor (UUID) -> RemoteConnectionLease?)?
    var richPasteUploadOperationForTesting: TerminalRichPasteUploadOperation?
    var resizeOperationForTesting: (@MainActor (TerminalResizeRequestSize, TerminalEntityID) async -> Void)?
    var processExitOperationForTesting: (@MainActor (TerminalEntityID) async -> Void)?
    #endif
    @Published private(set) var isSuspendingForBackground = false

    /// Servers that already ran tmux cleanup (per app launch)
    var tmuxCleanupStore = TerminalTmuxCleanupStore()

    // MARK: - LRU Terminal Cache

    /// Maximum number of terminal surfaces to keep in memory
    /// Each Ghostty surface uses ~50-100MB (font atlas, Metal textures, scrollback)
    let maxTerminals = 20

    let snapshotStore = ConnectionSessionsSnapshotStore()
    var persistTask: Task<Void, Never>?
    var isRestoring = false

    private init() {
        restoreSnapshot()
    }

    func sessionWithID(_ sessionId: UUID) -> ConnectionSession? {
        sessions.first { $0.id == sessionId }
    }

    func setSuspendingForBackground(_ isSuspending: Bool) {
        isSuspendingForBackground = isSuspending
    }

    func clearRuntimeTitle(for sessionId: UUID) {
        runtimeTitleBySession.removeValue(forKey: sessionId)
    }

    func setLastMoshInstallFailure(_ error: Error?) {
        lastMoshInstallFailure = error
    }

    func indexOfSession(_ sessionId: UUID) -> Int? {
        sessions.firstIndex { $0.id == sessionId }
    }

    func firstSession(for serverId: UUID) -> ConnectionSession? {
        sessions.first { $0.serverId == serverId }
    }

    func storedWorkingDirectory(for sessionId: UUID) -> String? {
        sessionWithID(sessionId)?.workingDirectory
    }

    func setStoredWorkingDirectory(_ workingDirectory: String, for sessionId: UUID) {
        guard let index = indexOfSession(sessionId) else { return }
        sessions[index].workingDirectory = workingDirectory
    }

    func setPresentationOverrides(_ presentationOverrides: TerminalPresentationOverrides, for sessionId: UUID) {
        guard let index = indexOfSession(sessionId) else { return }
        sessions[index].presentationOverrides = presentationOverrides
    }

    func tmuxStatus(for sessionId: UUID) -> TmuxStatus? {
        sessionWithID(sessionId)?.tmuxStatus
    }

    func setTmuxStatus(_ status: TmuxStatus, for sessionId: UUID) {
        guard let index = indexOfSession(sessionId) else { return }
        sessions[index].tmuxStatus = status
    }

    func setTransport(
        _ transport: ShellTransport,
        fallbackReason: MoshFallbackReason?,
        for sessionId: UUID
    ) {
        guard let index = indexOfSession(sessionId) else { return }
        sessions[index].activeTransport = transport
        sessions[index].moshFallbackReason = fallbackReason
    }

    // MARK: - Session Management

    var selectedSession: ConnectionSession? {
        guard let id = selectedSessionId else { return nil }
        return sessionWithID(id)
    }

    var activeSessions: [ConnectionSession] {
        let liveEntityIDs = sessions.reduce(into: Set<TerminalEntityID>()) { result, session in
            let serverLiveEntityIDs = terminalConnectionRegistry.openingOrStreamingEntityIDs(for: session.serverId)
            result.formUnion(serverLiveEntityIDs)
        }
        return sessions.filter { liveEntityIDs.contains(.session($0.id)) }
    }

    private var liveActivitySnapshots: [TerminalLiveActivitySnapshot] {
        sessions.compactMap { session in
            let entityId = TerminalEntityID.session(session.id)
            guard let state = terminalConnectionRegistry.state(for: entityId) else { return nil }
            guard state.isConnected || state.isOpening else { return nil }
            return TerminalLiveActivitySnapshot(
                sessionId: session.id,
                serverId: session.serverId,
                state: state
            )
        }
    }

    var canOpenNewTab: Bool {
        if StoreManager.shared.isPro { return true }
        return sessions.filter(\.isTabRoot).count < FreeTierLimits.maxTabs
    }

    func waitForSurfaceAttachRequest(_ requestID: UUID) async {
        await surfaceAttachRequestStore[requestID]?.task.value
    }

    func waitForProcessExitRequest(_ requestID: UUID) async {
        await processExitRequestStore[requestID]?.task.value
    }

    func waitForActiveConnectionOpenRequest(_ requestID: UUID) async {
        await activeConnectionOpenRequestStore[requestID]?.task?.value
    }

    func waitForForegroundReconnectRequest(_ requestID: UUID) async {
        await foregroundReconnectRequestStore[requestID]?.task?.value
    }

    // MARK: - Connection State Updates

    func updateSessionState(_ sessionId: UUID, to state: ConnectionState) {
        guard let index = indexOfSession(sessionId) else { return }

        var updatedSession = sessions[index]
        updatedSession.connectionState = state
        let serverId = updatedSession.serverId
        terminalConnectionRegistry.updateState(
            TerminalEntityConnectionState(connectionState: state),
            for: .session(sessionId),
            serverId: serverId
        )
        sessions[index] = updatedSession

        switch state {
        case .connected:
            successfulConnectionRecorder(
                sessionId,
                successfulConnectionTransport(for: sessionId).rawValue
            )
        case .disconnected, .failed:
            if case .failed = state {
                sessions[index].presentationOverrides = .empty
                terminalSurfaceRegistry.surface(for: .session(sessionId))?.applyPresentationOverrides(.empty)
            }
            if sessions[index].tmuxStatus == .foreground {
                setTmuxStatus(.background, for: sessionId)
            }
        case .connecting, .reconnecting:
            sessions[index].activeTransport = .ssh
            sessions[index].moshFallbackReason = nil
        case .idle:
            break
        }
    }

    private func successfulConnectionTransport(for sessionId: UUID) -> ShellTransport {
        shellRegistry.registration(for: sessionId)?.transport
            ?? .ssh
    }

    func sessionState(for sessionId: UUID) -> ConnectionState? {
        sessionWithID(sessionId)?.connectionState
    }

    func hasOtherActiveSessions(for serverId: UUID, excluding sessionId: UUID) -> Bool {
        terminalConnectionRegistry.hasActiveEntity(
            for: serverId,
            excluding: .session(sessionId)
        )
    }

    /// Returns true when the same SSH client instance is registered to another live session.
    /// This is used to avoid disconnecting a truly shared client during retry cleanup.
    func hasOtherRegistrations(using client: SSHClient, excluding sessionId: UUID) -> Bool {
        shellRegistry.hasOtherRegistrations(using: client, excluding: sessionId)
    }

    func updateTmuxStatus(_ sessionId: UUID, status: TmuxStatus) {
        setTmuxStatus(status, for: sessionId)
    }

    func updateSessionWorkingDirectory(_ sessionId: UUID, rawDirectory: String) {
        guard let normalized = normalizeWorkingDirectory(rawDirectory) else { return }
        setStoredWorkingDirectory(normalized, for: sessionId)
    }

    func updateSessionTitle(_ sessionId: UUID, rawTitle: String) {
        guard sessionWithID(sessionId) != nil else { return }
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        guard runtimeTitleBySession[sessionId] != title else { return }

        runtimeTitleBySession[sessionId] = title
        logger.info("Runtime session title changed: \(title, privacy: .public)")
    }

    func presentationOverrides(for sessionId: UUID) -> TerminalPresentationOverrides {
        sessionWithID(sessionId)?.presentationOverrides ?? .empty
    }

    func handleTerminalZoom(_ action: TerminalZoomAction, for sessionId: UUID) -> TerminalZoomResult? {
        guard sessionWithID(sessionId) != nil else { return nil }

        let currentOverrides = presentationOverrides(for: sessionId)
        let overrides = currentOverrides.applyingZoom(action)
        guard overrides != currentOverrides else {
            return TerminalZoomResult(
                presentationOverrides: currentOverrides,
                effectiveFontSize: currentOverrides.resolvedFontSize()
            )
        }
        setPresentationOverrides(overrides, for: sessionId)
        schedulePersist()
        terminalSurfaceRegistry.surface(for: .session(sessionId))?.applyPresentationOverrides(overrides)
        return TerminalZoomResult(
            presentationOverrides: overrides,
            effectiveFontSize: overrides.resolvedFontSize()
        )
    }

    func displayTitle(for session: ConnectionSession) -> String {
        runtimeTitleBySession[session.id] ?? session.title
    }

    // MARK: - Tab Navigation

    func selectSession(_ session: ConnectionSession) {
        selectedSessionId = session.id
    }

    func selectPreviousSession() {
        guard let currentId = selectedSessionId,
              let currentIndex = indexOfSession(currentId),
              currentIndex > 0 else { return }
        selectedSessionId = sessions[currentIndex - 1].id
    }

    func selectNextSession() {
        guard let currentId = selectedSessionId,
              let currentIndex = indexOfSession(currentId),
              currentIndex < sessions.count - 1 else { return }
        selectedSessionId = sessions[currentIndex + 1].id
    }

    func selectSession(at index: Int) {
        guard index >= 0 && index < sessions.count else { return }
        selectedSessionId = sessions[index].id
    }

    /// Send text to the terminal for a given session (used by voice input)
    func sendText(_ text: String, to sessionId: UUID) {
        guard let terminal = terminalSurfaceRegistry.surface(for: .session(sessionId)) else { return }
        terminal.sendText(text)
    }
}
