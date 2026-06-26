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
    private var connectionOpenRequestStore = TerminalOpenRequestStore()
    private(set) var lastConnectionOpenFailure: Error?
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
    private var connectWatchdogStore = TerminalConnectWatchdogStore()
    var credentialsProvider: @MainActor (Server) async throws -> ServerCredentials = { server in
        try KeychainManager.shared.getCredentials(for: server)
    }
    /// Per-server teardown work from ordinary tab closes. New opens wait for this too.
    var serverTeardownTaskStore = TerminalTeardownTaskStore()
    /// Application-owned tab SSH runtimes. SwiftUI coordinators attach surfaces and send intent only.
    var sessionRuntimes: [UUID: SessionRuntimeState] = [:]
    let terminalConnectionRegistry = TerminalConnectionRegistry()
    #if DEBUG
    private var testingTerminalConnectionClientFactory: (@MainActor (TerminalEntityID, Server?) -> any TerminalConnectionClient)?
    var rejectedShellCleanupOperationForTesting: (@MainActor @Sendable () async -> Void)?
    var tmuxKillOperationForTesting: (@MainActor @Sendable () async -> Void)?
    var tmuxInstallOperationForTesting: (@MainActor (UUID) async -> Void)?
    var moshInstallAndReconnectOperationForTesting: (@MainActor (ConnectionSession) async throws -> Void)?
    var sessionRetryOperationForTesting: (@MainActor (ConnectionSession, Server?) async -> TerminalReconnectRequestResult)?
    var activeConnectionOpenReconnectOperationForTesting: (@MainActor (ConnectionSession) async -> Bool)?
    var foregroundReconnectOperationForTesting: (@MainActor (ConnectionSession) async -> Bool)?
    var sessionHostRetrustOperationForTesting: (@MainActor (ConnectionSession, Server) async -> Bool)?
    private var surfaceAttachOperationForTesting: (@MainActor (TerminalEntityID) async -> Void)?
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

    private func firstSession(for serverId: UUID) -> ConnectionSession? {
        sessions.first { $0.serverId == serverId }
    }

    private func registryLiveSession(for serverId: UUID) -> ConnectionSession? {
        let liveEntityIDs = terminalConnectionRegistry.openingOrStreamingEntityIDs(for: serverId)
        if let selected = selectedSession(for: serverId),
           liveEntityIDs.contains(.session(selected.id)) {
            return selected
        }

        return sessions.first {
            $0.serverId == serverId && liveEntityIDs.contains(.session($0.id))
        }
    }

    private func selectedSession(for serverId: UUID) -> ConnectionSession? {
        if let selectedSessionId = selectedSessionByServer[serverId] {
            return sessionWithID(selectedSessionId)
        }

        guard let selectedSessionId,
              let session = sessionWithID(selectedSessionId),
              session.serverId == serverId else {
            return nil
        }

        return session
    }

    private func sourceSessionForNewTab(on serverId: UUID) -> ConnectionSession? {
        if let selectedSessionId = selectedSessionByServer[serverId],
           let session = sessionWithID(selectedSessionId),
           session.serverId == serverId {
            return session
        }

        if let selectedSessionId,
           let session = sessionWithID(selectedSessionId),
           session.serverId == serverId {
            return session
        }

        return firstSession(for: serverId)
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

    private func handleStaleShellStartContext(
        _ staleContext: SSHShellRegistry.StartContext?,
        logMessage: StaticString,
        sessionId: UUID
    ) {
        guard let staleContext else { return }

        logger.warning("\(logMessage) \(sessionId.uuidString, privacy: .public)")
        if !shellRegistry.hasClientReferences(staleContext.client) {
            trackShellCleanup(
                for: staleContext.serverId,
                reason: "stale session start"
            ) { [client = staleContext.client] in
                await client.disconnect()
            }
        }
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

    // MARK: - Open Connection

    @discardableResult
    func requestConnectionOpen(
        to server: Server,
        forceNew: Bool = false,
        onOpened: @escaping @MainActor (ConnectionSession) -> Void = { _ in },
        onFailed: @escaping @MainActor (Error) -> Void = { _ in }
    ) -> UUID {
        let requestID = UUID()
        lastConnectionOpenFailure = nil

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.connectionOpenRequestStore.remove(id: requestID) }

            do {
                let session = try await self.openConnection(to: server, forceNew: forceNew)
                onOpened(session)
            } catch is CancellationError {
                return
            } catch {
                self.lastConnectionOpenFailure = error
                onFailed(error)
            }
        }

        connectionOpenRequestStore.insert(task, id: requestID)
        return requestID
    }

    func waitForConnectionOpenRequest(_ requestID: UUID) async {
        await connectionOpenRequestStore[requestID]?.value
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

    /// Opens a connection to a server
    /// - Parameters:
    ///   - server: The server to connect to
    ///   - forceNew: If true, always creates a new tab even if one exists for this server
    func openConnection(to server: Server, forceNew: Bool = false) async throws -> ConnectionSession {
        if let disconnectTask = serverDisconnectTaskStore.task(forServer: server.id) {
            logger.info("Open waiting for disconnect cleanup [serverId: \(server.id.uuidString, privacy: .public)]")
            await disconnectTask.value
        }
        await waitForServerTeardownTasks(server.id)

        // Check if server is locked due to downgrade
        if ServerManager.shared.isServerLocked(server) {
            throw VVTermError.serverLocked(server.name)
        }

        if !connectionOpenRequestStore.beginOpen(forScope: server.id) {
            throw VVTermError.connectionFailed(
                String(localized: "A connection is already opening for this server.")
            )
        }
        defer { connectionOpenRequestStore.finishOpen(forScope: server.id) }

        guard await AppLockManager.shared.ensureServerUnlocked(server) else {
            throw VVTermError.authenticationFailed
        }

        // Check if already have a session for this server (unless forcing new)
        if !forceNew, let existingSession = firstSession(for: server.id) {
            selectedSessionId = existingSession.id
            let hasLiveOrOpeningRuntime = terminalConnectionRegistry.isOpeningOrStreaming(.session(existingSession.id))
            if !hasLiveOrOpeningRuntime {
                try await reconnect(session: existingSession)
            }
            return existingSession
        }

        guard canOpenNewTab else {
            throw VVTermError.proRequired(String(localized: "Upgrade to Pro for multiple connections"))
        }

        let sourceSession = sourceSessionForNewTab(on: server.id)
        var sourceWorkingDirectory = sourceSession?.workingDirectory
        if tmuxResolver.isTmuxEnabled(for: server.id),
           let sourceSession,
           let client = sshClient(for: sourceSession),
           let path = await RemoteTmuxManager.shared.currentPath(
               sessionName: tmuxResolver.sessionName(for: sourceSession.id),
               using: client
           ) {
            sourceWorkingDirectory = path
            if let index = indexOfSession(sourceSession.id) {
                sessions[index].workingDirectory = path
            }
        }

        // Create new session - actual SSH connection happens in SSHTerminalWrapper
        let session = ConnectionSession(
            serverId: server.id,
            title: server.name,
            connectionState: .connecting,  // Will connect when terminal view appears
            tmuxStatus: tmuxResolver.isTmuxEnabled(for: server.id) ? .unknown : .off,
            workingDirectory: sourceWorkingDirectory
        )

        sessions.append(session)
        selectedSessionId = session.id

        // Update server's last connected after the navigation animation completes
        Task { [server] in
            try? await Task.sleep(for: .milliseconds(350))
            await ServerManager.shared.updateLastConnected(for: server)
        }

        logger.info("Created session for \(server.name)")
        return session
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

    func shouldScheduleConnectWatchdog(
        forSessionId sessionId: UUID,
        isReady: Bool,
        terminalExists: Bool
    ) -> Bool {
        guard let state = sessionState(for: sessionId) else { return false }
        return state.isConnecting || (state.isConnected && !isReady && !terminalExists)
    }

    func scheduleConnectWatchdog(
        forSessionId sessionId: UUID,
        isReady: Bool,
        terminalExists: Bool,
        timeout: Duration = .seconds(20),
        timeoutMessage: String,
        onRetry: @escaping @MainActor () async -> Void
    ) {
        connectWatchdogStore.removeTask(for: sessionId)?.cancel()

        guard shouldScheduleConnectWatchdog(
            forSessionId: sessionId,
            isReady: isReady,
            terminalExists: terminalExists
        ) else {
            connectWatchdogStore.clear(for: sessionId)?.cancel()
            return
        }

        let generation = connectWatchdogStore.beginGeneration(for: sessionId)
        let task = Task { @MainActor [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            guard let self else { return }
            guard self.connectWatchdogStore.isCurrent(generation, for: sessionId) else { return }

            let action = self.handleConnectWatchdogTimeout(
                forSessionId: sessionId,
                isReady: isReady,
                terminalExists: terminalExists,
                timeoutMessage: timeoutMessage
            )

            switch action {
            case .retry:
                self.connectWatchdogStore.clear(for: sessionId)
                await onRetry()
            case .continueWatching:
                self.scheduleConnectWatchdog(
                    forSessionId: sessionId,
                    isReady: isReady,
                    terminalExists: terminalExists,
                    timeout: timeout,
                    timeoutMessage: timeoutMessage,
                    onRetry: onRetry
                )
            case .none:
                self.connectWatchdogStore.clear(for: sessionId)
            }
        }
        connectWatchdogStore.setTask(task, for: sessionId)
    }

    func handleConnectWatchdogTimeout(
        forSessionId sessionId: UUID,
        isReady: Bool,
        terminalExists: Bool,
        timeoutMessage: String
    ) -> TerminalConnectWatchdogAction {
        guard let state = sessionState(for: sessionId) else { return .none }
        let connectedWithoutTerminal = state.isConnected && !isReady && !terminalExists
        guard state.isConnecting || connectedWithoutTerminal else { return .none }

        if connectedWithoutTerminal {
            updateSessionState(sessionId, to: .disconnected)
            return .retry
        }

        if shellId(for: sessionId) != nil {
            updateSessionState(sessionId, to: .connected)
            return .none
        }

        if isShellStartInFlight(for: sessionId) {
            return .continueWatching
        }

        updateSessionState(sessionId, to: .failed(timeoutMessage))
        return .none
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

    // MARK: - SSH Client Registration

    @discardableResult
    func registerSSHClient(
        _ client: SSHClient,
        shellId: UUID,
        for sessionId: UUID,
        serverId: UUID,
        transport: ShellTransport = .ssh,
        fallbackReason: MoshFallbackReason? = nil,
        skipTmuxLifecycle: Bool = false
    ) -> Bool {
        registerSSHClient(
            client,
            shellId: shellId,
            for: sessionId,
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
        for sessionId: UUID,
        serverId: UUID,
        transport: ShellTransport = .ssh,
        fallbackReason: MoshFallbackReason? = nil,
        generation: SSHShellRegistry.Generation?,
        skipTmuxLifecycle: Bool = false
    ) -> Bool {
        guard sessionWithID(sessionId) != nil else {
            logger.warning("Ignoring shell registration for missing session [sessionId: \(sessionId.uuidString, privacy: .public), serverId: \(serverId.uuidString, privacy: .public)]")
            trackShellCleanup(
                for: serverId,
                reason: "missing session shell"
            ) { [client, shellId] in
                await client.closeShell(shellId)
                await client.disconnect()
            }
            return false
        }

        let registerResult = shellRegistry.register(
            client: client,
            shellId: shellId,
            for: sessionId,
            serverId: serverId,
            transport: transport,
            fallbackReason: fallbackReason,
            generation: generation
        )

        if let stale = registerResult.staleIncomingShell {
            logger.warning("Ignoring stale shell registration [sessionId: \(sessionId.uuidString, privacy: .public), serverId: \(serverId.uuidString, privacy: .public)]")
            trackShellCleanup(
                for: serverId,
                reason: "rejected session shell"
            ) { [client = stale.client, shellId = stale.shellId] in
                await client.closeShell(shellId)
                await client.disconnect()
            }
            return false
        }

        if let replaced = registerResult.replacedShell {
            trackShellCleanup(
                for: serverId,
                reason: "replaced session shell"
            ) { [client = replaced.client, shellId = replaced.shellId] in
                await client.closeShell(shellId)
            }
        }

        setTransport(transport, fallbackReason: fallbackReason, for: sessionId)
        terminalsNeedingReconnectReset.remove(sessionId)

        if !skipTmuxLifecycle {
            Task { [weak self] in
                await self?.handleTmuxLifecycle(sessionId: sessionId, serverId: serverId, client: client, shellId: shellId)
            }
        }
        return true
    }

    private func sshClient(for session: ConnectionSession) -> SSHClient? {
        shellRegistry.client(for: session.id)
    }

    private func sshClient(forSessionId sessionId: UUID) -> SSHClient? {
        shellRegistry.client(for: sessionId)
    }

    func remoteConnectionLease(forSessionId sessionId: UUID) -> RemoteConnectionLease? {
        sshClient(forSessionId: sessionId).map {
            RemoteConnectionLease(client: $0, ownership: .borrowed)
        }
    }

    func shellId(for session: ConnectionSession) -> UUID? {
        shellRegistry.shellId(for: session.id)
    }

    func shellId(for sessionId: UUID) -> UUID? {
        shellRegistry.shellId(for: sessionId)
    }

    /// Returns true only for the first caller while no live shell exists for the session.
    func tryBeginShellStart(for sessionId: UUID, client: SSHClient) -> Bool {
        beginShellStart(for: sessionId, client: client)?.started == true
    }

    func beginShellStart(for sessionId: UUID, client: SSHClient) -> SSHShellRegistry.StartResult? {
        guard let serverId = sessionWithID(sessionId)?.serverId else {
            return nil
        }

        let startResult = shellRegistry.tryBeginStart(
            for: sessionId,
            serverId: serverId,
            client: client
        )

        handleStaleShellStartContext(
            startResult.staleContext,
            logMessage: "Recovered stale session shell-start lock for",
            sessionId: sessionId
        )
        return startResult
    }

    func finishShellStart(for sessionId: UUID, client: SSHClient, generation: SSHShellRegistry.Generation? = nil) {
        shellRegistry.finishStart(for: sessionId, client: client, generation: generation)
    }

    func isShellStartInFlight(for sessionId: UUID) -> Bool {
        let result = shellRegistry.isStartInFlight(for: sessionId)
        handleStaleShellStartContext(
            result.staleContext,
            logMessage: "Cleared stale session shell-start in-flight flag for",
            sessionId: sessionId
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
        if let selectedId = selectedSessionId,
           let selectedSession = sessionWithID(selectedId),
           selectedSession.serverId == serverId,
           let registration = shellRegistry.registration(for: selectedSession.id) {
            return registration
        }

        if let anySession = firstSession(for: serverId),
           let registration = shellRegistry.registration(for: anySession.id) {
            return registration
        }

        return shellRegistry.firstRegistration(for: serverId)
    }

    private func sshClient(for serverId: UUID) -> SSHClient? {
        preferredSSHClient(for: serverId, allowPendingStart: true)
    }

    private func activeSSHClient(for serverId: UUID) -> SSHClient? {
        preferredSSHClient(for: serverId, allowPendingStart: false)
    }

    private func sharedStatsClient(for serverId: UUID) -> SSHClient? {
        if let liveSession = registryLiveSession(for: serverId) {
            guard let registration = shellRegistry.registration(for: liveSession.id),
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

    func configureRuntime(
        for sessionId: UUID,
        server: Server,
        credentials: ServerCredentials,
        onProcessExit: @escaping () -> Void
    ) {
        if let runtime = sessionRuntimes[sessionId] {
            runtime.server = server
            runtime.credentials = credentials
            runtime.onProcessExit = onProcessExit
            return
        }

        let entityId = TerminalEntityID.session(sessionId)
        let runtime = makeTerminalConnectionRuntime(entityId: entityId, server: server)
        terminalConnectionRegistry.register(runtime, for: entityId, serverId: server.id)
        sessionRuntimes[sessionId] = SessionRuntimeState(
            sessionId: sessionId,
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

    func startRuntimeIfNeeded(for sessionId: UUID, terminal: GhosttyTerminalView) async {
        guard let runtime = runtimeStateForStarting(sessionId: sessionId) else { return }
        await startRuntimeIfNeeded(runtime, terminal: terminal)
    }

    private func runtimeStateForStarting(sessionId: UUID) -> SessionRuntimeState? {
        if let runtime = sessionRuntimes[sessionId] {
            return runtime
        }

        guard let session = sessionWithID(sessionId),
              let server = ServerManager.shared.servers.first(where: { $0.id == session.serverId }) else {
            updateSessionState(sessionId, to: .failed("Server not found"))
            return nil
        }

        do {
            let credentials = try KeychainManager.shared.getCredentials(for: server)
            configureRuntime(for: sessionId, server: server, credentials: credentials, onProcessExit: {})
            return sessionRuntimes[sessionId]
        } catch {
            updateSessionState(sessionId, to: .failed(error.localizedDescription))
            return nil
        }
    }

    private func startRuntimeIfNeeded(_ runtime: SessionRuntimeState, terminal: any TerminalConnectionSurface) async {
        let sessionId = runtime.sessionId

        if await runtime.runtime.hasShellTask() {
            logger.debug("Ignoring duplicate start request for session \(sessionId.uuidString, privacy: .public)")
            return
        }

        if let existingShellId = shellId(for: sessionId) {
            await runtime.runtime.setShellId(existingShellId)
            updateSessionState(sessionId, to: .connected)
            logger.debug("Reusing existing shell for session \(sessionId.uuidString, privacy: .public)")
            return
        }

        if await runtime.runtime.currentShellId() != nil {
            updateSessionState(sessionId, to: .connected)
            return
        }

        let sshClient = await runtime.runtime.runnerClient()
        guard let startResult = beginShellStart(for: sessionId, client: sshClient),
              startResult.started else {
            if shellId(for: sessionId) != nil {
                updateSessionState(sessionId, to: .connected)
            }
            logger.debug("Shell start already in progress for session \(sessionId.uuidString, privacy: .public)")
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
                    ConnectionSessionManager.shared.finishShellStart(
                        for: sessionId,
                        client: sshClient,
                        generation: shellGeneration
                    )
                    if let runtime = ConnectionSessionManager.shared.sessionRuntimes[sessionId]?.runtime {
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
                        ConnectionSessionManager.shared.updateSessionState(sessionId, to: .connecting)
                    } else {
                        ConnectionSessionManager.shared.updateSessionState(sessionId, to: .reconnecting(attempt: attempt))
                    }
                },
                startupPlan: {
                    await ConnectionSessionManager.shared.tmuxStartupPlan(
                        for: sessionId,
                        serverId: server.id,
                        client: sshClient
                    )
                },
                registerShell: { shell, skipTmuxLifecycle in
                    let accepted = ConnectionSessionManager.shared.registerSSHClient(
                        sshClient,
                        shellId: shell.id,
                        for: sessionId,
                        serverId: server.id,
                        transport: shell.transport,
                        fallbackReason: shell.fallbackReason,
                        generation: shellGeneration,
                        skipTmuxLifecycle: skipTmuxLifecycle
                    )
                    guard accepted else { return false }
                    await ConnectionSessionManager.shared.sessionRuntimes[sessionId]?.runtime.setShellId(shell.id)
                    ConnectionSessionManager.shared.updateSessionState(sessionId, to: .connected)
                    return true
                },
                onBeforeShellStart: { cols, rows in
                    await ConnectionSessionManager.shared.sessionRuntimes[sessionId]?.runtime.updateLastSize(cols: cols, rows: rows)
                },
                onShellStarted: { _, shellId in
                    await ConnectionSessionManager.shared.applyWorkingDirectoryIfNeeded(
                        for: sessionId,
                        client: sshClient,
                        shellId: shellId
                    )
                },
                onTitleChange: { title in
                    ConnectionSessionManager.shared.updateSessionTitle(sessionId, rawTitle: title)
                },
                shouldContinueStreaming: { data, terminal in
                    let sessionExists = ConnectionSessionManager.shared.sessions.contains { $0.id == sessionId }
                    guard sessionExists else { return false }
                    terminal.writeConnectionOutput(data)
                    return true
                },
                shouldResetClient: { sshError in
                    switch sshError {
                    case .notConnected, .connectionFailed, .socketError, .timeout, .libssh2:
                        return true
                    case .channelOpenFailed, .shellRequestFailed:
                        let hasOtherRegistrations = await ConnectionSessionManager.shared.hasOtherRegistrations(
                            using: sshClient,
                            excluding: sessionId
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
                    ConnectionSessionManager.shared.updateSessionState(sessionId, to: .failed(error.localizedDescription))
                }
            )
        }
        await runtime.runtime.setShellTask(shellTask)
    }

    func registeredShellRoute(for sessionId: UUID) -> (client: SSHClient, shellId: UUID)? {
        guard let client = sshClient(forSessionId: sessionId),
              let shellId = shellId(for: sessionId) else {
            return nil
        }
        return (client: client, shellId: shellId)
    }

    func suspendRuntime(for sessionId: UUID) async {
        guard let runtime = sessionRuntimes[sessionId] else { return }
        await runtime.runtime.suspend()
    }

    func cancelRuntime(
        for sessionId: UUID,
        mode: ShellTeardownMode,
        cleanupTerminal: Bool
    ) async {
        let runtime = sessionRuntimes[sessionId]
        await runtime?.runtime.cancelShellTask()
        let shellId = await runtime?.runtime.clearShellId()

        if cleanupTerminal {
            terminalSurfaceRegistry.removeSurface(for: .session(sessionId), cleanup: true)
        }

        guard let runtime else { return }
        if let shellId {
            await runtime.runtime.closeRunnerShell(shellId)
        }
        if mode == .fullDisconnect {
            await runtime.runtime.disconnectRunnerClientAndClear()
            sessionRuntimes.removeValue(forKey: sessionId)
            terminalConnectionRegistry.discardRuntime(for: .session(sessionId))
        }
    }

    private func applyWorkingDirectoryIfNeeded(
        for sessionId: UUID,
        client: SSHClient,
        shellId: UUID
    ) async {
        let cwd: String? = await MainActor.run {
            guard ConnectionSessionManager.shared.shouldApplyWorkingDirectory(for: sessionId) else { return nil }
            return ConnectionSessionManager.shared.workingDirectory(for: sessionId)
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

    /// Send text to the terminal for a given session (used by voice input)
    func sendText(_ text: String, to sessionId: UUID) {
        guard let terminal = terminalSurfaceRegistry.surface(for: .session(sessionId)) else { return }
        terminal.sendText(text)
    }

}

#if DEBUG
extension ConnectionSessionManager {
    /// Resets manager state for deterministic integration tests.
    func resetForTesting() async {
        persistTask?.cancel()
        persistTask = nil
        await waitForAllServerTeardownTasks()

        let allSessionIds = Set(sessions.map(\.id))
            .union(shellRegistry.startsInFlight.keys)
        for sessionId in allSessionIds {
            clearTmuxRuntimeState(for: sessionId)
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
        liveActivityRefresh = { LiveActivityManager.shared.refresh(with: $0) }
        successfulConnectionRecorder = { EngagementTracker.shared.recordSuccessfulConnection(id: $0, transport: $1) }
        sessions = []
        selectedSessionId = nil
        selectedViewByServer = [:]
        selectedSessionByServer = [:]
        tmuxAttachPrompt = nil
        shellRegistry.removeAll()
        shellHandlerStore.removeAll()
        connectionOpenRequestStore.removeAll().forEach { $0.cancel() }
        lastConnectionOpenFailure = nil
        tmuxInstallRequestStore.allRequests.forEach { $0.task.cancel() }
        tmuxInstallRequestStore.removeAll()
        moshInstallRequestStore.allRequests.forEach { $0.task.cancel() }
        moshInstallRequestStore.removeAll()
        lastMoshInstallFailure = nil
        sessionRetryRequestStore.allRequests.forEach { $0.task.cancel() }
        sessionRetryRequestStore.removeAll()
        activeConnectionOpenRequestStore.allRequests.compactMap(\.task).forEach { $0.cancel() }
        activeConnectionOpenRequestStore.removeAll()
        foregroundReconnectRequestStore.allRequests.compactMap(\.task).forEach { $0.cancel() }
        foregroundReconnectRequestStore.removeAll()
        sessionHostRetrustRequestStore.allRequests.forEach { $0.task.cancel() }
        sessionHostRetrustRequestStore.removeAll()
        sessionCredentialLoadRequestStore.allRequests.forEach { $0.task.cancel() }
        sessionCredentialLoadRequestStore.removeAll()
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
        serverDisconnectTaskStore.removeAll()
        terminalsNeedingReconnectReset.removeAll()
        isSuspendingForBackground = false
        tmuxCleanupStore.removeAll()
        sessionRuntimes.removeAll()
        terminalConnectionRegistry.removeAll()
        testingTerminalConnectionClientFactory = nil
        rejectedShellCleanupOperationForTesting = nil
        tmuxKillOperationForTesting = nil
        tmuxInstallOperationForTesting = nil
        moshInstallAndReconnectOperationForTesting = nil
        sessionRetryOperationForTesting = nil
        activeConnectionOpenReconnectOperationForTesting = nil
        sessionHostRetrustOperationForTesting = nil
        surfaceAttachOperationForTesting = nil
        inputOperationForTesting = nil
        richPasteLeaseProviderForTesting = nil
        richPasteUploadOperationForTesting = nil
        resizeOperationForTesting = nil
        processExitOperationForTesting = nil
        isRestoring = false

        snapshotStore.remove()
        for terminal in terminals {
            terminal.cleanup()
        }
        for client in uniqueClients.values {
            await client.disconnect()
        }
    }

    func setBackgroundSuspendInProgressForTesting(_ isSuspending: Bool) {
        isSuspendingForBackground = isSuspending
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
        sessionId: UUID,
        context: TerminalSurfaceAttachContext,
        resetTerminal: @escaping @MainActor () -> Void = {}
    ) -> UUID? {
        requestSurfaceAttach(
            sessionId: sessionId,
            context: context,
            resetTerminal: resetTerminal,
            attachOperation: { [weak self] in
                guard let self else { return }
                if let surfaceAttachOperationForTesting = self.surfaceAttachOperationForTesting {
                    await surfaceAttachOperationForTesting(.session(sessionId))
                }
            }
        )
    }

    func setServerDisconnectTaskForTesting(_ serverId: UUID, task: Task<Void, Never>?) {
        serverDisconnectTaskStore.setTask(task, forServer: serverId)
    }

    func setTerminalConnectionClientFactoryForTesting(
        _ factory: @escaping @MainActor (TerminalEntityID, Server?) -> any TerminalConnectionClient
    ) {
        testingTerminalConnectionClientFactory = factory
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
        _ operation: (@MainActor (ConnectionSession) async throws -> Void)?
    ) {
        moshInstallAndReconnectOperationForTesting = operation
    }

    func setSessionRetryOperationForTesting(
        _ operation: (@MainActor (ConnectionSession, Server?) async -> TerminalReconnectRequestResult)?
    ) {
        sessionRetryOperationForTesting = operation
    }

    func setActiveConnectionOpenReconnectOperationForTesting(
        _ operation: (@MainActor (ConnectionSession) async -> Bool)?
    ) {
        activeConnectionOpenReconnectOperationForTesting = operation
    }

    func cancelActiveConnectionOpenRequestForTesting(_ requestID: UUID) {
        activeConnectionOpenRequestStore[requestID]?.task?.cancel()
    }

    func setForegroundReconnectOperationForTesting(
        _ operation: (@MainActor (ConnectionSession) async -> Bool)?
    ) {
        foregroundReconnectOperationForTesting = operation
    }

    func setSessionHostRetrustOperationForTesting(
        _ operation: (@MainActor (ConnectionSession, Server) async -> Bool)?
    ) {
        sessionHostRetrustOperationForTesting = operation
    }

    func setCredentialsProviderForTesting(
        _ provider: @escaping @MainActor (Server) async throws -> ServerCredentials
    ) {
        credentialsProvider = provider
    }

    func registerTerminalForTesting(sessionId: UUID) {
        evictOldTerminalsIfNeeded()
        terminalSurfaceRegistry.registerForTesting(
            entityId: .session(sessionId),
            pause: {},
            cleanup: {}
        )
    }

    func beginShellStartForTesting(
        sessionId: UUID,
        serverId: UUID,
        client: SSHClient
    ) -> SSHShellRegistry.Generation {
        shellRegistry.tryBeginStart(
            for: sessionId,
            serverId: serverId,
            client: client
        ).generation
    }

    func closeShellRegistrationForTesting(sessionId: UUID) {
        _ = shellRegistry.closeEntity(sessionId)
    }

    func hasTerminalConnectionRuntimeForTesting(_ entityId: TerminalEntityID) -> Bool {
        terminalConnectionRegistry.runtime(for: entityId) != nil
    }

    func setRuntimeShellTaskForTesting(
        sessionId: UUID,
        _ task: Task<Void, Never>
    ) async {
        guard let runtime = sessionRuntimes[sessionId] else { return }
        await runtime.runtime.setShellTask(task)
        registerShellCancelHandler({ [weak self] mode in
            await self?.cancelRuntime(for: sessionId, mode: mode, cleanupTerminal: false)
        }, for: sessionId)
    }

    func completeRuntimeShellStartForTesting(
        sessionId: UUID,
        client: SSHClient,
        shellId: UUID,
        serverId: UUID,
        generation: SSHShellRegistry.Generation
    ) -> Bool {
        let accepted = registerSSHClient(
            client,
            shellId: shellId,
            for: sessionId,
            serverId: serverId,
            generation: generation,
            skipTmuxLifecycle: true
        )
        guard accepted else { return false }
        updateSessionState(sessionId, to: .connected)
        return true
    }

    func startRuntimeForTesting(sessionId: UUID) async {
        guard let session = sessionWithID(sessionId) else {
            return
        }

        let server = ServerManager.shared.servers.first { $0.id == session.serverId }
        let entityId = session.terminalEntityId
        let runtime: TerminalConnectionRuntime
        if let existing = terminalConnectionRegistry.runtime(for: entityId) {
            runtime = existing
        } else {
            runtime = makeTerminalConnectionRuntime(entityId: entityId, server: server)
            terminalConnectionRegistry.register(runtime, for: entityId, serverId: session.serverId)
        }
        await runtime.open(configuration: .testing)
        if await runtime.state == .streaming {
            updateSessionState(sessionId, to: .connected)
        }
    }

    func restorePersistedSnapshotForTesting() {
        restoreSnapshot()
    }
}
#endif
