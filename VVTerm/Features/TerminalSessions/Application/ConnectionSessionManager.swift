import Foundation
import Combine
import os.log
#if os(macOS)
import AppKit
#endif
#if os(iOS)
import UIKit
#endif

enum ShellTeardownMode: Equatable, Sendable {
    case closeShellOnly
    case fullDisconnect
}

enum TerminalSurfaceDetachReason: Equatable, Sendable {
    case viewDisappeared
    case sessionClosed
}

@MainActor
final class ConnectionSessionManager: ObservableObject {
    static let shared = ConnectionSessionManager()

    private struct SSHUnregisterResult: Sendable {
        let shellToClose: (client: SSHClient, shellId: UUID)?
        let clientToDisconnect: SSHClient?
    }

    private struct SessionCloseResult {
        let sessionId: UUID
        let serverId: UUID
        let tmuxSessionNameToKill: String?
        let shellTeardownTask: Task<Void, Never>?
    }

    private final class SessionRuntimeState {
        let sessionId: UUID
        var server: Server
        var credentials: ServerCredentials
        let runtime: TerminalConnectionRuntime
        var onProcessExit: () -> Void

        init(
            sessionId: UUID,
            server: Server,
            credentials: ServerCredentials,
            runtime: TerminalConnectionRuntime,
            onProcessExit: @escaping () -> Void
        ) {
            self.sessionId = sessionId
            self.server = server
            self.credentials = credentials
            self.runtime = runtime
            self.onProcessExit = onProcessExit
        }
    }

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

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "ConnectionSession")
    private var shellRegistry = SSHShellRegistry(staleThreshold: 120)

    /// Terminal UI surfaces indexed by session entity. SSH runtime ownership is separate.
    private let terminalSurfaceRegistry = TerminalSurfaceRegistry()
    /// Sessions whose preserved terminal must be reset before attaching a fresh shell.
    private var terminalsNeedingReconnectReset: Set<UUID> = []

    /// Shell cancel handlers indexed by session ID - called before closing to cancel async tasks
    private var shellCancelHandlers: [UUID: @MainActor (_ mode: ShellTeardownMode) async -> Void] = [:]
    /// Shell suspend handlers indexed by session ID - cancel in-flight connects without destroying terminals
    private var shellSuspendHandlers: [UUID: @MainActor () async -> Void] = [:]
    /// Server IDs with an in-flight open request, used to collapse repeated clicks.
    private var sessionOpensInFlight: Set<UUID> = []
    /// Server disconnect cleanups in progress. New opens wait for the matching cleanup.
    private var serverDisconnectTasks: [UUID: Task<Void, Never>] = [:]
    /// Per-server teardown work from ordinary tab closes. New opens wait for this too.
    private var serverTeardownTasks: [UUID: [UUID: Task<Void, Never>]] = [:]
    /// Application-owned tab SSH runtimes. SwiftUI coordinators attach surfaces and send intent only.
    private var sessionRuntimes: [UUID: SessionRuntimeState] = [:]
    private let terminalConnectionRegistry = TerminalConnectionRegistry()
    #if DEBUG
    private var testingTerminalConnectionClientFactory: (@MainActor (TerminalEntityID, Server?) -> any TerminalConnectionClient)?
    private var rejectedShellCleanupOperationForTesting: (@MainActor @Sendable () async -> Void)?
    private var tmuxKillOperationForTesting: (@MainActor @Sendable () async -> Void)?
    #endif
    @Published private(set) var isSuspendingForBackground = false

    /// Servers that already ran tmux cleanup (per app launch)
    private var tmuxCleanupServers: Set<UUID> = []

    // MARK: - LRU Terminal Cache

    /// Maximum number of terminal surfaces to keep in memory
    /// Each Ghostty surface uses ~50-100MB (font atlas, Metal textures, scrollback)
    private let maxTerminals = 20

    private let persistenceKey = "connectionSessionsSnapshot.v1"
    private var persistTask: Task<Void, Never>?
    private var isRestoring = false

    private init() {
        restoreSnapshot()
    }

    private func sessionWithID(_ sessionId: UUID) -> ConnectionSession? {
        sessions.first { $0.id == sessionId }
    }

    private func indexOfSession(_ sessionId: UUID) -> Int? {
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

    private func storedWorkingDirectory(for sessionId: UUID) -> String? {
        sessionWithID(sessionId)?.workingDirectory
    }

    private func setStoredWorkingDirectory(_ workingDirectory: String, for sessionId: UUID) {
        guard let index = indexOfSession(sessionId) else { return }
        sessions[index].workingDirectory = workingDirectory
    }

    private func setPresentationOverrides(_ presentationOverrides: TerminalPresentationOverrides, for sessionId: UUID) {
        guard let index = indexOfSession(sessionId) else { return }
        sessions[index].presentationOverrides = presentationOverrides
    }

    private func tmuxStatus(for sessionId: UUID) -> TmuxStatus? {
        sessionWithID(sessionId)?.tmuxStatus
    }

    private func setTmuxStatus(_ status: TmuxStatus, for sessionId: UUID) {
        guard let index = indexOfSession(sessionId) else { return }
        sessions[index].tmuxStatus = status
    }

    private func setTransport(
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

    private func clearTmuxRuntimeState(for sessionId: UUID) {
        tmuxResolver.clearRuntimeState(for: sessionId, setPrompt: setTmuxAttachPrompt)
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

    /// Opens a connection to a server
    /// - Parameters:
    ///   - server: The server to connect to
    ///   - forceNew: If true, always creates a new tab even if one exists for this server
    func openConnection(to server: Server, forceNew: Bool = false) async throws -> ConnectionSession {
        if let disconnectTask = serverDisconnectTasks[server.id] {
            logger.info("Open waiting for disconnect cleanup [serverId: \(server.id.uuidString, privacy: .public)]")
            await disconnectTask.value
        }
        await waitForServerTeardownTasks(server.id)

        // Check if server is locked due to downgrade
        if ServerManager.shared.isServerLocked(server) {
            throw VVTermError.serverLocked(server.name)
        }

        if sessionOpensInFlight.contains(server.id) {
            throw VVTermError.connectionFailed(
                String(localized: "A connection is already opening for this server.")
            )
        }
        sessionOpensInFlight.insert(server.id)
        defer { sessionOpensInFlight.remove(server.id) }

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

    // MARK: - Close Terminal

    /// Closes a terminal session and removes it from the list
    func closeSession(_ session: ConnectionSession, notingSessionEnd: Bool = true) {
        guard let closeResult = closeSessionUI(session, notingSessionEnd: notingSessionEnd) else { return }
        let unregisterTask = scheduleSSHUnregister(
            for: closeResult.sessionId,
            priority: .high,
            killingManagedTmuxSessionNamed: closeResult.tmuxSessionNameToKill
        )
        let teardownTask = Task {
            await unregisterTask.value
            await closeResult.shellTeardownTask?.value
        }
        trackServerTeardownTask(teardownTask, for: closeResult.serverId)
    }

    /// Closes a terminal session and waits for shell cancellation and SSH teardown to finish.
    func closeSessionAndWait(_ session: ConnectionSession, notingSessionEnd: Bool = true) async {
        await waitForServerTeardownTasks(session.serverId)
        guard let closeResult = closeSessionUI(session, notingSessionEnd: notingSessionEnd) else { return }
        await unregisterSSHClient(
            for: closeResult.sessionId,
            killingManagedTmuxSessionNamed: closeResult.tmuxSessionNameToKill
        )
        await closeResult.shellTeardownTask?.value
    }

    private func closeSessionUI(_ session: ConnectionSession, notingSessionEnd: Bool) -> SessionCloseResult? {
        let sessionId = session.id
        let title = session.title
        let wasSelected = selectedSessionId == sessionId

        guard sessionWithID(sessionId) != nil else { return nil }

        let tmuxSessionToKill = managedTmuxSessionNameToKill(for: sessionId, status: session.tmuxStatus)

        let replacementSessionId = replacementSessionIDAfterClosing(
            sessionId: sessionId,
            serverId: session.serverId,
            wasSelected: wasSelected
        )

        let shellTeardownTask = clearRuntimeStateForClosedSession(sessionId)
        terminalConnectionRegistry.updateState(
            .disconnected,
            for: .session(sessionId),
            serverId: session.serverId
        )

        // Remove from UI immediately
        sessions.removeAll { $0.id == sessionId }

        // Select another session if this was selected (prefer same server)
        if wasSelected {
            selectedSessionId = replacementSessionId
        }

        handleTerminalCloseUI(
            sessionId: sessionId,
            wasSelected: wasSelected,
            replacementSessionId: replacementSessionId
        )

        if let selectedId = replacementSessionId ?? selectedSessionId,
           let selectedSession = sessionWithID(selectedId) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.redrawSessionAfterClose(selectedSession)
            }
        }

        if notingSessionEnd {
            EngagementTracker.shared.noteTerminalSessionEnded(
                otherTerminalsActive: !activeSessions.isEmpty,
                isPro: StoreManager.shared.isPro
            )
        }

        logger.info("Closed terminal session \(title)")
        return SessionCloseResult(
            sessionId: sessionId,
            serverId: session.serverId,
            tmuxSessionNameToKill: tmuxSessionToKill,
            shellTeardownTask: shellTeardownTask
        )
    }

    private func replacementSessionIDAfterClosing(
        sessionId: UUID,
        serverId: UUID,
        wasSelected: Bool
    ) -> UUID? {
        guard wasSelected else { return nil }

        let serverSessions = sessions.filter { $0.serverId == serverId }
        if let index = serverSessions.firstIndex(where: { $0.id == sessionId }) {
            if index + 1 < serverSessions.count {
                return serverSessions[index + 1].id
            }
            if index > 0 {
                return serverSessions[index - 1].id
            }
        }

        return sessions.first(where: { $0.id != sessionId })?.id
    }

    private func clearRuntimeStateForClosedSession(_ sessionId: UUID) -> Task<Void, Never>? {
        let shellTeardownTask = cancelAndClearShellHandlers(for: sessionId)
        terminalsNeedingReconnectReset.remove(sessionId)
        terminalBrowseModeBySession.removeValue(forKey: sessionId)
        clearTmuxRuntimeState(for: sessionId)
        runtimeTitleBySession.removeValue(forKey: sessionId)
        return shellTeardownTask
    }

    private func handleTerminalCloseUI(
        sessionId: UUID,
        wasSelected: Bool,
        replacementSessionId: UUID?
    ) {
        if let terminal = terminalSurfaceRegistry.surface(for: .session(sessionId)), terminal.window != nil {
            terminal.pauseRendering()
            if !wasSelected {
                _ = terminal.resignFirstResponder()
            }
        } else {
            unregisterTerminal(for: sessionId)
        }

        guard let replacementSessionId,
              let replacementTerminal = terminalSurfaceRegistry.surface(for: .session(replacementSessionId)),
              replacementTerminal.window != nil else {
            return
        }

        DispatchQueue.main.async {
            #if os(iOS)
            guard UIApplication.shared.applicationState == .active else { return }
            replacementTerminal.requestKeyboardFocus(for: .initialActivation)
            #else
            _ = replacementTerminal.window?.makeFirstResponder(replacementTerminal)
            #endif
        }
    }

    private func redrawSessionAfterClose(_ session: ConnectionSession) {
        guard let terminal = terminalSurfaceRegistry.surface(for: .session(session.id)) else { return }
        terminal.resumeRendering()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self, weak terminal] in
            guard let terminal = terminal else { return }
            terminal.forceRefresh()

            if let size = terminal.terminalSize(),
               let self {
                Task {
                    await self.resizeSession(session.id, cols: Int(size.columns), rows: Int(size.rows))
                }
            }

            // Nudge the shell to redraw the prompt after layout changes without adding a new line.
            #if os(iOS)
            terminal.sendText("\u{0C}")
            #endif
        }
    }

    // MARK: - Disconnect All

    /// Fully disconnects all sessions for a server and clears connection state
    /// Closes every session during app termination — lifecycle teardown,
    /// not a user-initiated session end.
    func disconnectAll() {
        let sessionsToClose = sessions
        for session in sessionsToClose {
            closeSession(session, notingSessionEnd: false)
        }
        logger.info("Disconnected all sessions")
    }

    /// Closes every session and waits for SSH and shell teardown to finish.
    func disconnectAllAndWait() async {
        await waitForAllServerTeardownTasks()
        let sessionsToClose = sessions
        for session in sessionsToClose {
            await closeSessionAndWait(session, notingSessionEnd: false)
        }
        await waitForAllServerTeardownTasks()
        logger.info("Disconnected all sessions after awaiting teardown")
    }

    /// Disconnects all sessions without removing tabs (used when app backgrounds)
    func suspendAllForBackground() async {
        guard !isSuspendingForBackground else { return }
        isSuspendingForBackground = true
        defer { isSuspendingForBackground = false }

        pauseCachedTerminalsForBackground()
        let sessionsToSuspend = sessions
        var unregisterResults: [SSHUnregisterResult] = []
        unregisterResults.reserveCapacity(sessionsToSuspend.count)
        for session in sessionsToSuspend {
            if terminalConnectionRegistry.isOpeningOrStreaming(.session(session.id)) {
                updateSessionState(session.id, to: .disconnected)
                markTerminalForReconnectReset(for: session.id)
            }
            // Cancel any in-flight connects while preserving terminal state
            await shellSuspendHandlers[session.id]?()
            unregisterResults.append(takeSSHClientRegistration(for: session.id))
        }

        if unregisterResults.contains(where: { $0.shellToClose != nil || $0.clientToDisconnect != nil }) {
            await withTaskGroup(of: Void.self) { group in
                for unregisterResult in unregisterResults {
                    group.addTask {
                        await ConnectionSessionManager.finishSSHCleanup(for: unregisterResult)
                    }
                }
            }
        }

        logger.info("Suspended all sessions for background")
    }

    /// Handle shell exit without removing the session (keeps tab for reconnect)
    func handleShellExit(for sessionId: UUID) {
        setPresentationOverrides(.empty, for: sessionId)
        terminalSurfaceRegistry.surface(for: .session(sessionId))?.applyPresentationOverrides(.empty)
        updateSessionState(sessionId, to: .disconnected)
        markTerminalForReconnectReset(for: sessionId)
        scheduleSSHUnregister(for: sessionId)
    }

    /// Disconnect all sessions for a specific server
    func disconnectServer(_ serverId: UUID) {
        let sessionsToClose = sessions.filter { $0.serverId == serverId }
        for session in sessionsToClose {
            closeSession(session)
        }
        logger.info("Disconnected all sessions for server \(serverId)")
    }

    /// Disconnect all sessions for a server and wait until SSH clients/shells are unregistered.
    /// Use this for explicit user disconnects that may be followed immediately by a new connect.
    func disconnectServerAndWait(_ serverId: UUID) async {
        if let existingTask = serverDisconnectTasks[serverId] {
            await existingTask.value
            return
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performDisconnectServerAndWait(serverId)
        }
        serverDisconnectTasks[serverId] = task
        await task.value
        serverDisconnectTasks.removeValue(forKey: serverId)
    }

    private func performDisconnectServerAndWait(_ serverId: UUID) async {
        await waitForServerTeardownTasks(serverId)

        let sessionsToClose = sessions.filter { $0.serverId == serverId }
        var closeResults: [SessionCloseResult] = []
        closeResults.reserveCapacity(sessionsToClose.count)

        for session in sessionsToClose {
            if let closeResult = closeSessionUI(session, notingSessionEnd: true) {
                closeResults.append(closeResult)
            }
        }

        for closeResult in closeResults {
            await unregisterSSHClient(
                for: closeResult.sessionId,
                killingManagedTmuxSessionNamed: closeResult.tmuxSessionNameToKill
            )
            await closeResult.shellTeardownTask?.value
        }

        logger.info("Disconnected all sessions for server \(serverId)")
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

    // MARK: - Close Operations

    func closeOtherSessions(except session: ConnectionSession) {
        let toClose = sessions.filter { $0.id != session.id }
        for s in toClose {
            closeSession(s)
        }
    }

    func closeSessionsToLeft(of session: ConnectionSession) {
        guard let index = indexOfSession(session.id) else { return }
        let toClose = Array(sessions[..<index])
        for s in toClose {
            closeSession(s)
        }
    }

    func closeSessionsToRight(of session: ConnectionSession) {
        guard let index = indexOfSession(session.id) else { return }
        let toClose = Array(sessions[(index + 1)...])
        for s in toClose {
            closeSession(s)
        }
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

    func unregisterSSHClient(for sessionId: UUID) async {
        await unregisterSSHClient(for: sessionId, killingManagedTmuxSessionNamed: nil)
    }

    private func unregisterSSHClient(
        for sessionId: UUID,
        killingManagedTmuxSessionNamed tmuxSessionName: String?
    ) async {
        let unregisterResult = takeSSHClientRegistration(for: sessionId)
        if let tmuxSessionName,
           let client = unregisterResult.shellToClose?.client {
            let preferred = sessions.first(where: { $0.id == sessionId })
                .map { tmuxResolver.multiplexer(for: $0.serverId) } ?? .tmux
            await RemoteTmuxManager.shared.killSession(named: tmuxSessionName, using: client, preferred: preferred)
        }
        await Self.finishSSHCleanup(for: unregisterResult)
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

    // MARK: - Terminal Registration (with LRU caching)

    func registerTerminal(_ terminal: GhosttyTerminalView, for sessionId: UUID) {
        // Evict oldest terminals if we're at capacity
        evictOldTerminalsIfNeeded()

        #if os(iOS)
        terminal.onKeyboardBrowseModeChange = { [weak self] isBrowsing in
            Task { @MainActor [weak self] in
                self?.setTerminalBrowseMode(isBrowsing, for: sessionId)
            }
        }
        terminal.onFindNavigatorVisibilityChange = { [weak self] isVisible in
            Task { @MainActor [weak self] in
                self?.setTerminalFindNavigatorVisible(isVisible, for: sessionId)
            }
        }
        #endif
        terminalSurfaceRegistry.register(terminal, for: .session(sessionId))
        #if os(iOS)
        Task { @MainActor [weak self, weak terminal] in
            guard let self, let terminal, self.terminalSurfaceRegistry.surface(for: .session(sessionId)) === terminal else { return }
            self.setTerminalBrowseMode(terminal.isKeyboardInBrowseMode, for: sessionId)
            self.setTerminalFindNavigatorVisible(terminal.isFindNavigatorVisible, for: sessionId)
        }
        #endif

        logger.debug("Registered terminal for session, total: \(self.terminalSurfaceRegistry.count)/\(self.maxTerminals)")
    }

    func unregisterTerminal(for sessionId: UUID) {
        terminalSurfaceRegistry.removeSurface(for: .session(sessionId), cleanup: true)
        terminalsNeedingReconnectReset.remove(sessionId)
        #if os(iOS)
        Task { @MainActor [weak self] in
            self?.terminalBrowseModeBySession.removeValue(forKey: sessionId)
            self?.terminalFindNavigatorVisibleBySession.removeValue(forKey: sessionId)
        }
        #else
        terminalBrowseModeBySession.removeValue(forKey: sessionId)
        terminalFindNavigatorVisibleBySession.removeValue(forKey: sessionId)
        #endif
        logger.debug("Unregistered terminal, remaining: \(self.terminalSurfaceRegistry.count)")
    }

    /// Update access order for LRU tracking
    private func touchTerminal(_ sessionId: UUID) {
        terminalSurfaceRegistry.touch(.session(sessionId))
    }

    private func setTerminalBrowseMode(_ isBrowsing: Bool, for sessionId: UUID) {
        if terminalBrowseModeBySession[sessionId] != isBrowsing {
            terminalBrowseModeBySession[sessionId] = isBrowsing
        }
    }

    private func setTerminalFindNavigatorVisible(_ isVisible: Bool, for sessionId: UUID) {
        if terminalFindNavigatorVisibleBySession[sessionId] != isVisible {
            terminalFindNavigatorVisibleBySession[sessionId] = isVisible
        }
    }

    /// Evict least recently used terminals if over capacity
    private func evictOldTerminalsIfNeeded() {
        let selectedEntityId = selectedSessionId.map(TerminalEntityID.session)
        terminalSurfaceRegistry.evictOldest(maxCount: maxTerminals, preserving: selectedEntityId) { [weak self] entityId in
            guard let self else { return }
            guard case .session(let oldestId) = entityId else { return }
            logger.info("Evicting oldest terminal to free memory (count: \(self.terminalSurfaceRegistry.count))")
            let unregisterTask = scheduleSSHUnregister(for: oldestId)
            let shellTeardownTask = cancelAndClearShellHandlers(for: oldestId)
            guard let serverId = sessionWithID(oldestId)?.serverId else { return }
            let teardownTask = Task(priority: .utility) {
                await unregisterTask.value
                await shellTeardownTask?.value
            }
            trackServerTeardownTask(teardownTask, for: serverId)
        }
    }

    // MARK: - Shell Cancel Handler Registration

    func registerShellCancelHandler(_ handler: @escaping @MainActor (_ mode: ShellTeardownMode) async -> Void, for sessionId: UUID) {
        shellCancelHandlers[sessionId] = handler
    }

    func unregisterShellCancelHandler(for sessionId: UUID) {
        shellCancelHandlers.removeValue(forKey: sessionId)
    }

    func registerShellSuspendHandler(_ handler: @escaping @MainActor () async -> Void, for sessionId: UUID) {
        shellSuspendHandlers[sessionId] = handler
    }

    func unregisterShellSuspendHandler(for sessionId: UUID) {
        shellSuspendHandlers.removeValue(forKey: sessionId)
    }

    private func pauseCachedTerminalsForBackground() {
        #if os(iOS)
        for terminal in terminalSurfaceRegistry.allSurfaces {
            terminal.pauseRendering()
            if terminal.isFirstResponder {
                terminal.markKeyboardFocusForReconnect()
            }
            _ = terminal.resignFirstResponder()
        }
        #endif
    }

    func getTerminal(for sessionId: UUID) -> GhosttyTerminalView? {
        terminalSurfaceRegistry.accessedSurface(for: .session(sessionId))
    }

    /// Returns a terminal without mutating LRU state.
    func peekTerminal(for sessionId: UUID) -> GhosttyTerminalView? {
        terminalSurfaceRegistry.surface(for: .session(sessionId))
    }

    /// Returns whether a terminal exists without mutating LRU state.
    func hasTerminal(for sessionId: UUID) -> Bool {
        terminalSurfaceRegistry.hasSurface(for: .session(sessionId))
    }

    func markTerminalForReconnectReset(for sessionId: UUID) {
        terminalsNeedingReconnectReset.insert(sessionId)
    }

    func consumeTerminalReconnectReset(for sessionId: UUID) -> Bool {
        terminalsNeedingReconnectReset.remove(sessionId) != nil
    }

    private func cancelAndClearShellHandlers(for sessionId: UUID) -> Task<Void, Never>? {
        let handler = shellCancelHandlers.removeValue(forKey: sessionId)
        shellSuspendHandlers.removeValue(forKey: sessionId)
        guard let handler else {
            logger.info("No shell cancel handler registered for closed session [sessionId: \(sessionId.uuidString, privacy: .public)]")
            return nil
        }
        logger.info("Running shell cancel handler for closed session [sessionId: \(sessionId.uuidString, privacy: .public)]")
        return Task(priority: .high) { @MainActor in
            await handler(.fullDisconnect)
        }
    }

    func trackShellTeardownForClosedSession(
        sessionId: UUID,
        serverId: UUID,
        reason: String,
        operation: @escaping @MainActor () async -> Void
    ) {
        let task = Task(priority: .high) { @MainActor [logger] in
            logger.info("External shell teardown started [sessionId: \(sessionId.uuidString, privacy: .public), serverId: \(serverId.uuidString, privacy: .public), reason: \(reason, privacy: .public)]")
            await operation()
            logger.info("External shell teardown finished [sessionId: \(sessionId.uuidString, privacy: .public), serverId: \(serverId.uuidString, privacy: .public), reason: \(reason, privacy: .public)]")
        }
        trackServerTeardownTask(task, for: serverId)
    }

    private func waitForServerTeardownTasks(_ serverId: UUID) async {
        while let tasksById = serverTeardownTasks[serverId], !tasksById.isEmpty {
            logger.info("Open waiting for tab teardown cleanup [serverId: \(serverId.uuidString, privacy: .public), count: \(tasksById.count)]")
            for (taskId, task) in tasksById {
                await task.value
                finishServerTeardownTask(taskId, for: serverId)
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
        logger.info("Tracking server teardown [serverId: \(serverId.uuidString, privacy: .public), taskId: \(taskId.uuidString, privacy: .public), count: \(self.serverTeardownTasks[serverId]?.count ?? 0)]")

        Task { @MainActor [weak self] in
            await task.value
            guard let self else { return }
            self.finishServerTeardownTask(taskId, for: serverId)
        }
    }

    private func finishServerTeardownTask(_ taskId: UUID, for serverId: UUID) {
        guard serverTeardownTasks[serverId]?.removeValue(forKey: taskId) != nil else { return }
        if serverTeardownTasks[serverId]?.isEmpty == true {
            serverTeardownTasks.removeValue(forKey: serverId)
        }
        let remainingTasks = serverTeardownTasks[serverId]?.count ?? 0
        logger.info("Finished server teardown [serverId: \(serverId.uuidString, privacy: .public), taskId: \(taskId.uuidString, privacy: .public), remaining: \(remainingTasks)]")
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
            logger.info("Shell cleanup started [serverId: \(serverId.uuidString, privacy: .public), reason: \(reason, privacy: .public)]")
#if DEBUG
            if let testingOperation {
                await testingOperation()
            } else {
                await operation()
            }
#else
            await operation()
#endif
            logger.info("Shell cleanup finished [serverId: \(serverId.uuidString, privacy: .public), reason: \(reason, privacy: .public)]")
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
            logger.info("Managed tmux kill started [serverId: \(serverId.uuidString, privacy: .public), sessionName: \(sessionName, privacy: .public)]")
#if DEBUG
            if let testingOperation {
                await testingOperation()
            } else {
                await RemoteTmuxManager.shared.killSession(named: sessionName, using: client, preferred: preferred)
            }
#else
            await RemoteTmuxManager.shared.killSession(named: sessionName, using: client, preferred: preferred)
#endif
            logger.info("Managed tmux kill finished [serverId: \(serverId.uuidString, privacy: .public), sessionName: \(sessionName, privacy: .public)]")
        }
        trackServerTeardownTask(task, for: serverId)
    }

    @discardableResult
    private func scheduleSSHUnregister(
        for sessionId: UUID,
        priority: TaskPriority = .utility,
        killingManagedTmuxSessionNamed tmuxSessionName: String? = nil
    ) -> Task<Void, Never> {
        Task.detached(priority: priority) { [weak self] in
            await self?.unregisterSSHClient(
                for: sessionId,
                killingManagedTmuxSessionNamed: tmuxSessionName
            )
        }
    }

    /// Marks an existing terminal as recently used without fetching it for body evaluation.
    func markTerminalUsed(for sessionId: UUID) {
        guard terminalSurfaceRegistry.hasSurface(for: .session(sessionId)) else { return }
        touchTerminal(sessionId)
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

    func attachSurface(_ terminal: GhosttyTerminalView, to sessionId: UUID) async {
        if terminalSurfaceRegistry.surface(for: .session(sessionId)) !== terminal {
            registerTerminal(terminal, for: sessionId)
        }

        registerShellCancelHandler({ [weak self] mode in
            await self?.cancelRuntime(for: sessionId, mode: mode, cleanupTerminal: true)
        }, for: sessionId)
        registerShellSuspendHandler({ [weak self] in
            await self?.suspendRuntime(for: sessionId)
        }, for: sessionId)

        await startRuntimeIfNeeded(for: sessionId, terminal: terminal)
    }

    func detachSurface(from sessionId: UUID, reason: TerminalSurfaceDetachReason) async {
        switch reason {
        case .viewDisappeared:
            detachSurfaceForViewDisappeared(from: sessionId)
        case .sessionClosed:
            detachSurfaceForClosedSession(sessionId)
        }
    }

    func detachSurfaceForViewDisappeared(from sessionId: UUID) {
        terminalSurfaceRegistry.detachSurface(for: .session(sessionId), cleanup: false)
    }

    func detachSurfaceForClosedSession(_ sessionId: UUID) {
        unregisterTerminal(for: sessionId)
    }

    func handleClosedSessionSurfaceTeardown(
        sessionId: UUID,
        serverId: UUID,
        reason: String
    ) {
        trackShellTeardownForClosedSession(
            sessionId: sessionId,
            serverId: serverId,
            reason: reason
        ) { [weak self] in
            self?.detachSurfaceForClosedSession(sessionId)
        }
    }

    func sendInput(_ data: Data, to sessionId: UUID) async {
        if let runtime = terminalConnectionRegistry.runtime(for: .session(sessionId)) {
            do {
                try await runtime.send(data)
                return
            } catch SSHError.notConnected {
                // Input can arrive before shell registration; fallback routes
                // below handle existing registered shells without noisy logs.
            } catch {
                logger.error("Failed to send to SSH: \(error.localizedDescription)")
            }
        }

        guard let runtime = sessionRuntimes[sessionId] else {
            if let route = registeredShellRoute(for: sessionId) {
                try? await route.client.write(data, to: route.shellId)
            }
            return
        }

        if let shellId = await runtime.runtime.currentShellId(),
           let client = await runtime.runtime.runnerClientIfCreated() {
            do {
                try await client.write(data, to: shellId)
            } catch {
                logger.error("Failed to send to SSH: \(error.localizedDescription)")
            }
            return
        }

        if let route = registeredShellRoute(for: sessionId) {
            do {
                try await route.client.write(data, to: route.shellId)
            } catch {
                logger.error("Failed to send to SSH: \(error.localizedDescription)")
            }
        }
    }

    func resizeSession(_ sessionId: UUID, cols: Int, rows: Int) async {
        guard cols > 0 && rows > 0 else { return }

        if let runtime = terminalConnectionRegistry.runtime(for: .session(sessionId)) {
            do {
                try await runtime.resize(cols: cols, rows: rows)
                return
            } catch SSHError.notConnected {
                // The first resize often arrives before the remote shell exists.
            } catch {
                logger.warning("Failed to resize PTY: \(error.localizedDescription)")
            }
        }

        if let runtime = sessionRuntimes[sessionId] {
            if let shellId = await runtime.runtime.currentShellId(),
               let client = await runtime.runtime.runnerClientIfCreated() {
                do {
                    try await client.resize(cols: cols, rows: rows, for: shellId)
                } catch {
                    logger.warning("Failed to resize PTY: \(error.localizedDescription)")
                }
                return
            }
        }

        guard let route = registeredShellRoute(for: sessionId) else { return }
        do {
            try await route.client.resize(cols: cols, rows: rows, for: route.shellId)
        } catch {
            logger.warning("Failed to resize PTY: \(error.localizedDescription)")
        }
    }

    private func startRuntimeIfNeeded(for sessionId: UUID, terminal: GhosttyTerminalView) async {
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

    private func registeredShellRoute(for sessionId: UUID) -> (client: SSHClient, shellId: UUID)? {
        guard let client = sshClient(forSessionId: sessionId),
              let shellId = shellId(for: sessionId) else {
            return nil
        }
        return (client: client, shellId: shellId)
    }

    private func suspendRuntime(for sessionId: UUID) async {
        guard let runtime = sessionRuntimes[sessionId] else { return }
        await runtime.runtime.suspend()
    }

    private func cancelRuntime(
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

    // MARK: - Reconnection

    func reconnect(session: ConnectionSession) async throws {
        guard !isSuspendingForBackground else { return }
        guard let serverManager = ServerManager.shared as ServerManager?,
              serverManager.servers.contains(where: { $0.id == session.serverId }) else {
            throw SSHError.connectionFailed("Server not found")
        }

        if terminalConnectionRegistry.isOpeningOrStreaming(.session(session.id)) {
            return
        }

        // Update state
        updateSessionState(session.id, to: .reconnecting(attempt: 1))
        markTerminalForReconnectReset(for: session.id)

        // Cancel in-flight shell work but keep the terminal surface for reuse
        await shellSuspendHandlers[session.id]?()

        // Disconnect existing SSH client
        await unregisterSSHClient(for: session.id)
    }

    private func takeSSHClientRegistration(for sessionId: UUID) -> SSHUnregisterResult {
        let unregisterResult = shellRegistry.unregister(for: sessionId)
        var shellToClose: (client: SSHClient, shellId: UUID)?
        var clientToDisconnect: SSHClient?

        if let registration = unregisterResult.registration {
            shellToClose = (client: registration.client, shellId: registration.shellId)
            if !shellRegistry.hasClientReferences(registration.client) {
                clientToDisconnect = registration.client
            }
        } else if let pendingStart = unregisterResult.pendingStart,
                  !shellRegistry.hasClientReferences(pendingStart.client) {
            clientToDisconnect = pendingStart.client
        }

        if unregisterResult.registration != nil {
            setTransport(.ssh, fallbackReason: nil, for: sessionId)
        }

        return SSHUnregisterResult(
            shellToClose: shellToClose,
            clientToDisconnect: clientToDisconnect
        )
    }

    private static func finishSSHCleanup(for unregisterResult: SSHUnregisterResult) async {
        if let shellToClose = unregisterResult.shellToClose {
            await shellToClose.client.closeShell(shellToClose.shellId)
        }

        if let clientToDisconnect = unregisterResult.clientToDisconnect {
            await clientToDisconnect.disconnect()
        }
    }

}

// MARK: - Persistence

extension ConnectionSessionManager {
    private func makeServerSnapshots() -> [ConnectionSessionsSnapshot.ServerSnapshot] {
        Set(sessions.map(\.serverId)).map { serverId in
            ConnectionSessionsSnapshot.ServerSnapshot(
                serverId: serverId,
                selectedSessionId: selectedSessionByServer[serverId],
                selectedView: selectedViewByServer[serverId]
            )
        }
    }

    private func makeSnapshot() -> ConnectionSessionsSnapshot {
        ConnectionSessionsSnapshot(
            sessions: sessions.map { ConnectionSessionsSnapshot.SessionSnapshot(from: $0) },
            selectedSessionId: selectedSessionId,
            serverSelections: makeServerSnapshots()
        )
    }

    private func applyRestoredSnapshot(_ snapshot: ConnectionSessionsSnapshot) {
        var restoredSessions = snapshot.sessions.map { $0.toSession() }
        for index in restoredSessions.indices {
            let serverId = restoredSessions[index].serverId
            if !tmuxResolver.isTmuxEnabled(for: serverId) {
                restoredSessions[index].tmuxStatus = .off
            }
        }

        sessions = restoredSessions
        selectedSessionId = snapshot.selectedSessionId
        selectedSessionByServer = Dictionary(
            uniqueKeysWithValues: snapshot.serverSelections.compactMap { snapshot in
                guard let selected = snapshot.selectedSessionId else { return nil }
                return (snapshot.serverId, selected)
            }
        )
        selectedViewByServer = Dictionary(
            uniqueKeysWithValues: snapshot.serverSelections.compactMap { snapshot in
                guard let view = snapshot.selectedView else { return nil }
                return (snapshot.serverId, view)
            }
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
            logger.error("Failed to persist session snapshot: \(error.localizedDescription)")
        }
    }

    private func restoreSnapshot() {
        guard let data = UserDefaults.standard.data(forKey: persistenceKey) else { return }
        do {
            let snapshot = try JSONDecoder().decode(ConnectionSessionsSnapshot.self, from: data)
            isRestoring = true
            applyRestoredSnapshot(snapshot)
        } catch {
            logger.error("Failed to restore session snapshot: \(error.localizedDescription)")
        }
        isRestoring = false
    }
}

private struct ConnectionSessionsSnapshot: Codable {
    struct SessionSnapshot: Codable {
        let id: UUID
        let serverId: UUID
        let title: String
        let createdAt: Date
        let lastActivity: Date
        let autoReconnect: Bool
        let parentSessionId: UUID?
        let workingDirectory: String?
        let presentationOverrides: TerminalPresentationOverrides?

        init(from session: ConnectionSession) {
            self.id = session.id
            self.serverId = session.serverId
            self.title = session.title
            self.createdAt = session.createdAt
            self.lastActivity = session.lastActivity
            self.autoReconnect = session.autoReconnect
            self.parentSessionId = session.parentSessionId
            self.workingDirectory = session.workingDirectory
            self.presentationOverrides = session.presentationOverrides.isEmpty ? nil : session.presentationOverrides
        }

        func toSession() -> ConnectionSession {
            ConnectionSession(
                id: id,
                serverId: serverId,
                title: title,
                connectionState: .disconnected,
                createdAt: createdAt,
                lastActivity: lastActivity,
                terminalSurfaceId: nil,
                autoReconnect: autoReconnect,
                workingDirectory: workingDirectory,
                presentationOverrides: presentationOverrides ?? .empty,
                parentSessionId: parentSessionId
            )
        }
    }

    struct ServerSnapshot: Codable {
        let serverId: UUID
        let selectedSessionId: UUID?
        let selectedView: String?
    }

    let sessions: [SessionSnapshot]
    let selectedSessionId: UUID?
    let serverSelections: [ServerSnapshot]
}

// MARK: - tmux Integration

extension ConnectionSessionManager {
    private func resolveTmuxWorkingDirectory(for sessionId: UUID, using client: SSHClient) async -> String {
        if let path = await RemoteTmuxManager.shared.currentPath(
            sessionName: tmuxResolver.sessionName(for: sessionId),
            using: client
        ) {
            setStoredWorkingDirectory(path, for: sessionId)
            return path
        }

        if let candidate = storedWorkingDirectory(for: sessionId)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !candidate.isEmpty {
            return candidate
        }

        return "~"
    }

    func workingDirectory(for sessionId: UUID) -> String? {
        storedWorkingDirectory(for: sessionId)
    }

    func shouldApplyWorkingDirectory(for sessionId: UUID) -> Bool {
        guard let status = tmuxStatus(for: sessionId) else { return false }
        return status == .off || status == .missing
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
        guard let selectedId = selectedSessionId else {
            for index in sessions.indices {
                if sessions[index].tmuxStatus == .foreground {
                    setTmuxStatus(.background, for: sessions[index].id)
                }
            }
            return
        }
        for index in sessions.indices {
            let status = sessions[index].tmuxStatus
            guard status == .foreground || status == .background else { continue }
            setTmuxStatus((sessions[index].id == selectedId) ? .foreground : .background, for: sessions[index].id)
        }
    }

    private func managedTmuxSessionNames(for serverId: UUID) -> Set<String> {
        var names: Set<String> = []
        for session in sessions where session.serverId == serverId {
            let ownership = tmuxResolver.sessionOwnership[session.id] ?? .managed
            guard ownership == .managed else { continue }
            names.insert(tmuxResolver.sessionName(for: session.id))
        }
        return names
    }

    private func tmuxSessionNamesToKeep(
        for serverId: UUID,
        sessionId: UUID,
        selection: TmuxAttachSelection
    ) -> Set<String> {
        var names = managedTmuxSessionNames(for: serverId)
        switch selection {
        case .skipTmux:
            break
        case .createManaged:
            names.insert(tmuxResolver.sessionName(for: sessionId))
        case .attachExisting(let sessionName):
            names.insert(sessionName)
        }
        return names
    }

    private func setTmuxAttachPrompt(_ prompt: TmuxAttachPrompt?) {
        tmuxAttachPrompt = prompt
    }

    func resolveTmuxAttachPrompt(sessionId: UUID, selection: TmuxAttachSelection) {
        tmuxResolver.resolvePrompt(entityId: sessionId, selection: selection, setPrompt: setTmuxAttachPrompt)
    }

    func cancelTmuxAttachPrompt(sessionId: UUID) {
        tmuxResolver.cancelPrompt(entityId: sessionId, setPrompt: setTmuxAttachPrompt)
    }

    private func currentTmuxStatus(for sessionId: UUID) -> TmuxStatus {
        selectedSessionId == sessionId ? .foreground : .background
    }

    private func disableTmuxAttachment(for sessionId: UUID, status: TmuxStatus) {
        tmuxResolver.clearAttachmentState(for: sessionId)
        updateTmuxStatus(sessionId, status: status)
    }

    private func runTmuxCleanupIfNeeded(
        for serverId: UUID,
        sessionId: UUID,
        selection: TmuxAttachSelection,
        using client: SSHClient
    ) async {
        var cleanupSet = tmuxCleanupServers
        await tmuxResolver.runCleanupIfNeeded(
            serverId: serverId,
            cleanupSet: &cleanupSet,
            managedNames: tmuxSessionNamesToKeep(for: serverId, sessionId: sessionId, selection: selection),
            using: client
        )
        tmuxCleanupServers = cleanupSet
    }

    private func prepareActiveTmuxSession(
        for sessionId: UUID,
        using client: SSHClient,
        backend: RemoteTmuxBackend
    ) async {
        updateTmuxStatus(sessionId, status: currentTmuxStatus(for: sessionId))
        let terminalType = await client.remoteTerminalType()
        await RemoteTmuxManager.shared.prepareConfig(using: client, terminalType: terminalType, backend: backend)
    }

    private func immediateTmuxSelection(for sessionId: UUID) -> TmuxAttachSelection {
        if tmuxResolver.sessionOwnership[sessionId] == .external {
            return .attachExisting(sessionName: tmuxResolver.sessionName(for: sessionId))
        }

        tmuxResolver.sessionNames[sessionId] = tmuxResolver.managedSessionName(for: sessionId)
        tmuxResolver.sessionOwnership[sessionId] = .managed
        return .createManaged
    }

    private func tmuxStartupCommand(
        for sessionId: UUID,
        selection: TmuxAttachSelection,
        workingDirectory: String,
        backend: RemoteTmuxBackend
    ) -> String? {
        switch selection {
        case .skipTmux:
            return nil
        case .createManaged:
            return RemoteTmuxManager.shared.attachCommand(
                sessionName: tmuxResolver.sessionName(for: sessionId),
                workingDirectory: workingDirectory,
                backend: backend
            )
        case .attachExisting(let sessionName):
            return RemoteTmuxManager.shared.attachExistingCommand(sessionName: sessionName, backend: backend)
        }
    }

    private func handleTmuxLifecycle(
        sessionId: UUID,
        serverId: UUID,
        client: SSHClient,
        shellId: UUID
    ) async {
        guard tmuxResolver.isTmuxEnabled(for: serverId) else {
            await MainActor.run {
                self.disableTmuxAttachment(for: sessionId, status: .off)
            }
            return
        }

        guard await client.supportsTmuxRuntime() else {
            logger.info("Resolved remote environment does not support tmux runtime for session \(sessionId.uuidString, privacy: .public); using plain SSH shell")
            await MainActor.run {
                self.disableTmuxAttachment(for: sessionId, status: .off)
            }
            return
        }

        guard let backend = await RemoteTmuxManager.shared.tmuxBackend(
            using: client,
            preferred: tmuxResolver.multiplexer(for: serverId)
        ) else {
            await MainActor.run {
                self.disableTmuxAttachment(for: sessionId, status: self.tmuxResolver.unavailableStatus(for: serverId))
            }
            return
        }

        let selection = immediateTmuxSelection(for: sessionId)

        await runTmuxCleanupIfNeeded(for: serverId, sessionId: sessionId, selection: selection, using: client)
        await prepareActiveTmuxSession(for: sessionId, using: client, backend: backend)

        let workingDirectory = await resolveTmuxWorkingDirectory(for: sessionId, using: client)
        guard let rebuilt = tmuxResolver.buildAttachExecCommand(
            for: sessionId,
            selection: selection,
            workingDirectory: workingDirectory,
            backend: backend
        ) else {
            return
        }

        await RemoteTmuxManager.shared.sendScript(rebuilt, using: client, shellId: shellId)
    }

    func tmuxStartupPlan(
        for sessionId: UUID,
        serverId: UUID,
        client: SSHClient
    ) async -> (command: String?, skipTmuxLifecycle: Bool) {
        guard tmuxResolver.isTmuxEnabled(for: serverId) else {
            disableTmuxAttachment(for: sessionId, status: .off)
            return (nil, true)
        }

        guard await client.supportsTmuxRuntime() else {
            disableTmuxAttachment(for: sessionId, status: .off)
            return (nil, true)
        }

        guard let backend = await RemoteTmuxManager.shared.tmuxBackend(
            using: client,
            preferred: tmuxResolver.multiplexer(for: serverId)
        ) else {
            disableTmuxAttachment(for: sessionId, status: tmuxResolver.unavailableStatus(for: serverId))
            return (nil, true)
        }

        let selection = await tmuxResolver.resolveSelection(
            for: sessionId, serverId: serverId, client: client, setPrompt: setTmuxAttachPrompt
        )
        tmuxResolver.updateAttachmentState(for: sessionId, serverId: serverId, selection: selection, setPrompt: setTmuxAttachPrompt)

        if case .skipTmux = selection {
            updateTmuxStatus(sessionId, status: .off)
            return (nil, true)
        }

        await runTmuxCleanupIfNeeded(for: serverId, sessionId: sessionId, selection: selection, using: client)
        await prepareActiveTmuxSession(for: sessionId, using: client, backend: backend)

        let workingDirectory = await resolveTmuxWorkingDirectory(for: sessionId, using: client)
        return (
            tmuxStartupCommand(
                for: sessionId,
                selection: selection,
                workingDirectory: workingDirectory,
                backend: backend
            ),
            true
        )
    }

    func startTmuxInstall(for sessionId: UUID) async {
        guard let registration = shellRegistry.registration(for: sessionId) else { return }
        let serverId = registration.serverId
        guard tmuxResolver.isTmuxEnabled(for: serverId) else { return }

        updateTmuxStatus(sessionId, status: .installing)

        let preferred = tmuxResolver.multiplexer(for: serverId)
        guard let backend = await RemoteTmuxManager.shared.tmuxInstallBackend(using: registration.client, preferred: preferred) else {
            updateTmuxStatus(sessionId, status: .off)
            return
        }

        let sessionName = tmuxResolver.sessionName(for: sessionId)
        let workingDirectory = await resolveTmuxWorkingDirectory(for: sessionId, using: registration.client)
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
                        self.tmuxResolver.bindManagedSession(for: sessionId, serverId: serverId)
                        self.updateTmuxStatus(sessionId, status: self.currentTmuxStatus(for: sessionId))
                    }
                    return
                }
            }
            await MainActor.run {
                self.updateTmuxStatus(sessionId, status: self.tmuxResolver.unavailableStatus(for: serverId))
            }
        }
    }

    func installMoshServer(for sessionId: UUID) async throws {
        guard let registration = shellRegistry.registration(for: sessionId) else {
            throw SSHError.notConnected
        }
        try await RemoteMoshManager.shared.installMoshServer(using: registration.client)
    }

    private func managedTmuxSessionNameToKill(for sessionId: UUID, status: TmuxStatus) -> String? {
        guard status == .foreground || status == .background || status == .installing else { return nil }
        let ownership = tmuxResolver.sessionOwnership[sessionId] ?? .managed
        guard ownership == .managed else { return nil }
        return tmuxResolver.sessionName(for: sessionId)
    }

    func killTmuxIfNeeded(for sessionId: UUID) {
        guard let registration = shellRegistry.registration(for: sessionId) else { return }
        let ownership = tmuxResolver.sessionOwnership[sessionId] ?? .managed
        guard ownership == .managed else { return }

        let sessionName = tmuxResolver.sessionName(for: sessionId)
        let preferred = tmuxResolver.multiplexer(for: registration.serverId)
        trackTmuxKill(
            for: registration.serverId,
            sessionName: sessionName,
            client: registration.client,
            preferred: preferred
        )
    }

    func disableTmux(for serverId: UUID) {
        for index in sessions.indices where sessions[index].serverId == serverId {
            let sessionId = sessions[index].id
            setTmuxStatus(.off, for: sessionId)
            clearTmuxRuntimeState(for: sessionId)
        }
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
        shellCancelHandlers.removeAll()
        shellSuspendHandlers.removeAll()
        sessionOpensInFlight.removeAll()
        serverDisconnectTasks.removeAll()
        terminalsNeedingReconnectReset.removeAll()
        isSuspendingForBackground = false
        tmuxCleanupServers.removeAll()
        sessionRuntimes.removeAll()
        terminalConnectionRegistry.removeAll()
        testingTerminalConnectionClientFactory = nil
        rejectedShellCleanupOperationForTesting = nil
        tmuxKillOperationForTesting = nil
        isRestoring = false

        UserDefaults.standard.removeObject(forKey: persistenceKey)
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

    func setServerDisconnectTaskForTesting(_ serverId: UUID, task: Task<Void, Never>?) {
        serverDisconnectTasks[serverId] = task
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

actor ConnectionReliabilityManager {
    private var reconnectAttempts = 0
    private let maxAttempts = 3
    private let baseDelay: TimeInterval = 1.0

    func handleDisconnect(session: ConnectionSession) async {
        guard session.autoReconnect else { return }

        while reconnectAttempts < maxAttempts {
            reconnectAttempts += 1
            let delay = baseDelay * pow(2, Double(reconnectAttempts - 1))

            try? await Task.sleep(for: .seconds(delay))

            do {
                try await ConnectionSessionManager.shared.reconnect(session: session)
                reconnectAttempts = 0
                return
            } catch {
                continue
            }
        }
    }

    func resetAttempts() {
        reconnectAttempts = 0
    }
}
