import SwiftUI
#if os(iOS)
import UIKit

struct iOSTerminalView: View {
    @ObservedObject var sessionManager: ConnectionSessionManager
    @ObservedObject var serverManager: ServerManager
    @ObservedObject var fileTabs: RemoteFileTabManager
    @ObservedObject var storeManager: StoreManager
    @ObservedObject var viewTabConfig: ViewTabConfigurationManager
    let disconnectCoordinator: ServerConnectionLifecycleCoordinator
    let fileBrowser: RemoteFileBrowserStore
    let statsRegistry: ServerStatsCollectionRegistry
    let connectionTester: ServerConnectionTester
    let connectingServer: Server?
    let isConnecting: Bool
    let onBack: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var terminalPreferences: TerminalRuntimePreferencesStore

    /// Delayed flag to allow tab animation to complete before creating terminal
    @State private var shouldShowTerminalBySession: [UUID: Bool] = [:]
    /// Force terminal rebuilds to restart SSH on foreground reconnect
    @State private var reconnectTokenBySession: [UUID: UUID] = [:]
    @State private var showingTabLimitAlert = false
    @State private var showingFileTabLimitAlert = false
    @State private var serverToEdit: Server?
    @State private var showingSettings = false
    @State private var terminalBackgroundColor: Color = .black
    @State private var currentServerId: UUID?
    @State private var pendingCloseSession: ConnectionSession?
    @State private var showingZenPanel = false
    @State private var requestedTerminalDismissal = false
    @State private var voiceRecordingBySession: [UUID: Bool] = [:]
    @State private var pendingVoiceReturnBySession: [UUID: Bool] = [:]

    @SceneStorage("vvterm.zenMode.ios") private var isZenModeEnabled = false

    private var effectiveThemeName: String {
        guard terminalPreferences.usePerAppearanceTheme else {
            return terminalPreferences.terminalThemeName
        }
        return colorScheme == .dark
            ? terminalPreferences.terminalThemeName
            : terminalPreferences.terminalThemeNameLight
    }

    private var serverSessions: [ConnectionSession] {
        guard let currentServerId else { return [] }
        return sessionManager.sessions.filter { $0.serverId == currentServerId }
    }

    private var selectedSession: ConnectionSession? {
        guard let resolvedId = effectiveSelectedSessionId else { return nil }
        return serverSessions.first { $0.id == resolvedId }
    }

    private var selectedServer: Server? {
        if let currentServerId {
            return serverManager.servers.first { $0.id == currentServerId }
        }
        return connectingServer
    }

    private var fileTabServerId: UUID? {
        IOSTerminalViewPolicy.fileTabServerId(currentServerId: currentServerId, selectedServerId: selectedServer?.id, connectingServerId: connectingServer?.id)
    }

    private var resolvedServerId: UUID? {
        IOSTerminalViewPolicy.resolvedServerId(
            currentServerId: currentServerId,
            selectedSessionServerId: selectedSession?.serverId,
            selectedServerId: selectedServer?.id,
            connectingServerId: connectingServer?.id
        )
    }

    private var serverFileTabs: [RemoteFileTab] {
        guard let fileTabServerId else { return [] }
        return fileTabs.tabs(for: fileTabServerId)
    }

    private var selectedFileTab: RemoteFileTab? {
        guard let fileTabServerId else { return nil }
        return fileTabs.selectedTab(for: fileTabServerId)
    }

    private var selectedFileTabIdBinding: Binding<UUID?> {
        Binding(
            get: { selectedFileTab?.id },
            set: { newValue in
                guard let newValue,
                      let tab = serverFileTabs.first(where: { $0.id == newValue }) else {
                    return
                }
                fileTabs.selectTab(tab)
            }
        )
    }

    private var selectedSessionIdBinding: Binding<UUID?> {
        Binding(
            get: { effectiveSelectedSessionId },
            set: { sessionManager.selectedSessionId = $0 }
        )
    }

    private var effectiveSelectedSessionId: UUID? {
        IOSTerminalViewPolicy.effectiveSelectedSessionId(
            selectedSessionId: sessionManager.selectedSessionId,
            serverSessionIds: serverSessions.map(\.id)
        )
    }

    private var selectedView: String {
        guard let serverId = resolvedServerId else {
            return viewTabConfig.effectiveDefaultTab()
        }
        return viewTabConfig.effectiveView(for: sessionManager.selectedViewByServer[serverId])
    }

    private var isSelectedTerminalInBrowseMode: Bool {
        guard let sessionId = effectiveSelectedSessionId else { return false }
        return sessionManager.terminalBrowseModeBySession[sessionId] ?? false
    }

    private var isSelectedTerminalFindNavigatorVisible: Bool {
        guard let sessionId = effectiveSelectedSessionId else { return false }
        return sessionManager.terminalFindNavigatorVisibleBySession[sessionId] ?? false
    }

    private var isSelectedTerminalVoiceRecording: Bool {
        guard let sessionId = effectiveSelectedSessionId else { return false }
        return voiceRecordingBySession[sessionId] ?? false
    }

    private var floatingControlsVisibility: IOSTerminalFloatingControlsVisibility {
        IOSTerminalViewPolicy.floatingControlsVisibility(
            isPhone: UIDevice.current.userInterfaceIdiom == .phone,
            selectedViewId: selectedView,
            isBrowseModeEnabled: isSelectedTerminalInBrowseMode,
            isFindNavigatorVisible: isSelectedTerminalFindNavigatorVisible,
            isVoiceRecording: isSelectedTerminalVoiceRecording,
            isVoiceButtonEnabled: terminalPreferences.terminalVoiceButtonEnabled,
            hasPendingVoiceReturn: effectiveSelectedSessionId.map {
                pendingVoiceReturnBySession[$0] == true
            } ?? false
        )
    }

    private var canUseZenMode: Bool {
        IOSTerminalViewPolicy.canUseZenMode(isConnecting: isConnecting, hasSelectedServer: selectedServer != nil, serverSessionCount: serverSessions.count)
    }

    private var effectiveZenModeEnabled: Bool {
        IOSTerminalViewPolicy.effectiveZenModeEnabled(isZenModeEnabled: isZenModeEnabled, canUseZenMode: canUseZenMode)
    }

    private var shouldShowViewSwitcher: Bool {
        IOSTerminalViewPolicy.shouldShowViewSwitcher(visibleTabCount: viewTabConfig.currentVisibleTabs.count)
    }

    private var zenSelectedViewBinding: Binding<String> {
        guard let serverId = resolvedServerId else {
            return .constant(viewTabConfig.effectiveDefaultTab())
        }
        return selectedViewBinding(for: serverId)
    }

    private func selectedViewBinding(for serverId: UUID) -> Binding<String> {
        Binding(
            get: { viewTabConfig.effectiveView(for: sessionManager.selectedViewByServer[serverId]) },
            set: { newValue in
                let current = viewTabConfig.effectiveView(for: sessionManager.selectedViewByServer[serverId])
                guard current != newValue else { return }
                sessionManager.selectedViewByServer[serverId] = IOSConnectionViewSelectionPolicy.storedViewId(
                    requestedViewId: newValue,
                    isRequestedViewVisible: viewTabConfig.isTabVisible(newValue),
                    effectiveDefaultViewId: viewTabConfig.effectiveDefaultTab()
                )
            }
        )
    }

    private func ensureInitialFileTabIfNeeded() {
        guard selectedView == ConnectionViewTab.files.id,
              let server = selectedServer else {
            return
        }

        let seedPath = selectedSession?.workingDirectory
        guard let fileTab = fileTabs.ensureInitialTab(for: server, seedPath: seedPath) else { return }
        fileBrowser.prepareNewTab(fileTab, duplicating: nil)
    }

    private func baseFileTabTitle(for tab: RemoteFileTab) -> String {
        RemoteFileTabTitlePolicy.baseTitle(
            for: fileTabTitleInput(for: tab),
            serverName: selectedServer?.name.nonEmptyString
        )
    }

    private func displayedFileTabTitle(for tab: RemoteFileTab) -> String {
        let resolvedTitles = RemoteFileTabTitlePolicy.displayedTitles(
            for: serverFileTabs.map { fileTabTitleInput(for: $0) },
            serverName: selectedServer?.name.nonEmptyString
        )
        return resolvedTitles[tab.id] ?? baseFileTabTitle(for: tab)
    }

    private func fileTabTitleInput(for tab: RemoteFileTab) -> RemoteFileTabTitleInput {
        RemoteFileTabTitleInput(
            id: tab.id,
            serverId: tab.serverId,
            seedPath: tab.seedPath,
            lastKnownPath: tab.lastKnownPath,
            lastVisitedPath: fileBrowser.lastVisitedPath(for: tab)
        )
    }

    private var tmuxAttachPromptBinding: Binding<TmuxAttachPrompt?> {
        Binding(
            get: {
                guard let prompt = sessionManager.tmuxAttachPrompt else { return nil }
                return serverSessions.contains(where: { $0.id == prompt.id }) ? prompt : nil
            },
            set: { newValue in
                guard newValue == nil, let prompt = sessionManager.tmuxAttachPrompt else { return }
                if serverSessions.contains(where: { $0.id == prompt.id }) {
                    sessionManager.cancelTmuxAttachPrompt(sessionId: prompt.id)
                }
            }
        )
    }

    private func updateTerminalBackgroundColor() {
        let fallback = colorScheme == .dark ? Color.black : Color(UIColor.systemBackground)
        let fallbackHex = colorScheme == .dark ? "#000000" : "#FFFFFF"
        let resolved = TerminalThemeBackgroundResolver.resolve(
            themeName: effectiveThemeName,
            fallbackHex: fallbackHex
        )
        terminalBackgroundColor = resolved.usedFallback ? fallback : resolved.color
        TerminalThemeBackgroundResolver.cacheResolvedBackground(resolved)
    }

    private func attemptForegroundReconnectIfNeeded(refreshTerminal: Bool = false) {
        sessionManager.requestForegroundReconnectForSelectedSession(
            selectedViewId: selectedView,
            terminalViewId: ConnectionViewTab.terminal.id,
            refreshTerminal: refreshTerminal,
            autoReconnectEnabled: terminalPreferences.autoReconnectEnabled
        ) { action in
            if action.shouldRefreshTerminal {
                activateTerminal(action.session)
            }

            if action.shouldReconnect {
                reconnectTokenBySession[action.sessionId] = UUID()
                shouldShowTerminalBySession[action.sessionId] = action.shouldForceTerminalVisible
            }
        }
    }

    private func recoverSelectedSessionIfNeeded() {
        guard let fallbackId = IOSTerminalViewPolicy.recoveredSelectedSessionId(
            currentServerId: currentServerId,
            selectedSessionId: sessionManager.selectedSessionId,
            serverSessionIds: serverSessions.map(\.id)
        ) else {
            return
        }
        sessionManager.selectedSessionId = fallbackId
    }

    private func pruneSessionScopedState() {
        let activeIds = Set(serverSessions.map(\.id))
        shouldShowTerminalBySession = IOSTerminalViewPolicy.prunedSessionState(
            shouldShowTerminalBySession,
            activeSessionIds: activeIds
        )
        reconnectTokenBySession = IOSTerminalViewPolicy.prunedSessionState(
            reconnectTokenBySession,
            activeSessionIds: activeIds
        )
        voiceRecordingBySession = IOSTerminalViewPolicy.prunedSessionState(
            voiceRecordingBySession,
            activeSessionIds: activeIds
        )
        pendingVoiceReturnBySession = IOSTerminalViewPolicy.prunedSessionState(
            pendingVoiceReturnBySession,
            activeSessionIds: activeIds
        )
    }

    var body: some View {
        baseContent
            .iosTerminalPresentation(
                isTabLimitPresented: $showingTabLimitAlert,
                isFileTabLimitPresented: $showingFileTabLimitAlert,
                isSettingsPresented: $showingSettings,
                serverToEdit: $serverToEdit,
                serverManager: serverManager,
                storeManager: storeManager,
                connectionTester: connectionTester,
                tmuxAttachPrompt: tmuxAttachPromptBinding,
                onResolveTmuxAttachPrompt: { prompt, selection in
                    sessionManager.resolveTmuxAttachPrompt(sessionId: prompt.id, selection: selection)
                },
                pendingCloseSession: $pendingCloseSession,
                onConfirmCloseSession: { session in
                    sessionManager.closeSession(session)
                    pendingCloseSession = nil
                },
                onCancelCloseSession: {
                    pendingCloseSession = nil
                }
            )
            .onAppear {
                updateTerminalBackgroundColor()
                if currentServerId == nil {
                    currentServerId = connectingServer?.id ?? sessionManager.selectedSession?.serverId
                }
                recoverSelectedSessionIfNeeded()
                synchronizeRecoveredTerminalState()
                ensureInitialFileTabIfNeeded()
                attemptForegroundReconnectIfNeeded(refreshTerminal: true)
            }
            .onChange(of: terminalPreferences.terminalThemeName) { _ in updateTerminalBackgroundColor() }
            .onChange(of: terminalPreferences.terminalThemeNameLight) { _ in updateTerminalBackgroundColor() }
            .onChange(of: terminalPreferences.usePerAppearanceTheme) { _ in updateTerminalBackgroundColor() }
            .onChange(of: colorScheme) { _ in updateTerminalBackgroundColor() }
            .onChange(of: scenePhase) { newPhase in
                if newPhase == .active {
                    updateTerminalBackgroundColor()
                    attemptForegroundReconnectIfNeeded(refreshTerminal: true)
                }
            }
            .onChange(of: connectingServer?.id) { newValue in
                if let newValue {
                    currentServerId = newValue
                }
                synchronizeRecoveredTerminalState()
                ensureInitialFileTabIfNeeded()
            }
            .onChange(of: sessionManager.selectedSessionId) { newValue in
                if let newValue,
                   let session = sessionManager.sessions.first(where: { $0.id == newValue }),
                   currentServerId != session.serverId {
                    currentServerId = session.serverId
                }
                synchronizeRecoveredTerminalState()
                ensureInitialFileTabIfNeeded()
                attemptForegroundReconnectIfNeeded()
            }
            .onChange(of: isConnecting) { _ in
                synchronizeRecoveredTerminalState()
            }
            .onChange(of: selectedView) { newValue in
                if newValue != "terminal" {
                    clearPendingVoiceReturnForCurrentSession()
                    dismissKeyboardForCurrentSession()
                } else {
                    DispatchQueue.main.async {
                        attemptForegroundReconnectIfNeeded(refreshTerminal: true)
                    }
                }
                ensureInitialFileTabIfNeeded()
            }
            .onChange(of: sessionManager.isSuspendingForBackground) { isSuspending in
                guard !isSuspending, scenePhase == .active else { return }
                attemptForegroundReconnectIfNeeded(refreshTerminal: true)
            }
            .onChange(of: isZenModeEnabled) { newValue in
                if newValue && !canUseZenMode {
                    isZenModeEnabled = false
                    return
                }
                if !newValue {
                    showingZenPanel = false
                }
                refreshTerminalAfterChromeChange()
            }
            .onChange(of: sessionManager.sessions) { _ in
                if currentServerId == nil, let selected = sessionManager.selectedSession {
                    currentServerId = selected.serverId
                }
                pruneSessionScopedState()
                recoverSelectedSessionIfNeeded()
                if selectedView == "terminal",
                   let selectedId = effectiveSelectedSessionId,
                   let session = serverSessions.first(where: { $0.id == selectedId }) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        refreshTerminal(for: session)
                        focusTerminal(for: session)
                    }
                }
                synchronizeRecoveredTerminalState()
                ensureInitialFileTabIfNeeded()
            }
    }

    private var baseContent: some View {
        IOSTerminalContentLayer(
            effectiveZenModeEnabled: effectiveZenModeEnabled,
            selectedView: selectedView,
            isConnecting: isConnecting,
            connectingServer: connectingServer,
            selectedServer: selectedServer,
            serverSessions: serverSessions,
            selectedSessionId: selectedSessionIdBinding,
            titleForSession: { sessionManager.displayTitle(for: $0) },
            onCloseSession: { pendingCloseSession = $0 },
            serverFileTabs: serverFileTabs,
            selectedFileTabId: selectedFileTabIdBinding,
            fileTabTitle: displayedFileTabTitle(for:),
            onSelectFileTab: { fileTabs.selectTab($0) },
            onCloseFileTab: closeFileTab,
            selectedFileTab: selectedFileTab,
            fileTabServerId: fileTabServerId,
            fileBrowser: fileBrowser,
            statsRegistry: statsRegistry,
            fileTabs: fileTabs,
            terminalBackgroundColor: terminalBackgroundColor,
            statsLeaseProvider: { serverId in sessionManager.sharedStatsLease(for: serverId) },
            serverManager: serverManager,
            sessionManager: sessionManager,
            viewTabConfig: viewTabConfig,
            shouldShowTerminalBySession: $shouldShowTerminalBySession,
            voiceRecordingBySession: $voiceRecordingBySession,
            pendingVoiceReturnBySession: $pendingVoiceReturnBySession,
            reconnectTokenForSession: { reconnectTokenBySession[$0.id] ?? $0.id },
            onActivateTerminal: activateTerminal,
            onRefreshTerminal: refreshTerminal(for:),
            onFocusTerminal: focusTerminal(for:),
            onEnsureInitialFileTab: ensureInitialFileTabIfNeeded,
            onNewTerminalTab: openNewTab,
            onNewFileTab: openNewFileTab
        )
            .overlay(alignment: .top) {
                if selectedView == "terminal" && !effectiveZenModeEnabled {
                    NavBarBackdrop(color: terminalBackgroundColor)
                }
            }
            .overlay(alignment: .topTrailing) {
                if effectiveZenModeEnabled {
                    IOSTerminalZenModeOverlay(
                        isPanelPresented: $showingZenPanel,
                        indicatorColor: selectedSession?.connectionState.statusTintColor ?? .secondary,
                        serverName: selectedServer?.name ?? String(localized: "Terminal"),
                        selectedView: selectedView,
                        selectedViewBinding: zenSelectedViewBinding,
                        visibleTabs: viewTabConfig.currentVisibleTabs,
                        sessions: serverSessions,
                        selectedSessionId: selectedSessionIdBinding,
                        sessionTitle: { sessionManager.displayTitle(for: $0) },
                        onCloseSession: { session in
                            pendingCloseSession = session
                        },
                        fileTabs: serverFileTabs,
                        selectedFileTabId: selectedFileTabIdBinding,
                        fileTabTitle: displayedFileTabTitle(for:),
                        onSelectFileTab: { tab in
                            fileTabs.selectTab(tab)
                        },
                        onCloseFileTab: closeFileTab,
                        onNewTerminalTab: openNewTab,
                        onNewFileTab: openNewFileTab,
                        onOpenSettings: {
                            showingSettings = true
                        },
                        editableServer: selectedServer,
                        onEditServer: { server in
                            serverToEdit = server
                        },
                        onDisconnect: disconnectCurrentServerSessions,
                        onBack: {
                            dismissKeyboardForCurrentSession()
                            onBack()
                        },
                        onExitZen: {
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                                isZenModeEnabled = false
                            }
                        }
                    )
                }
            }
            .overlay(alignment: .bottom) {
                if floatingControlsVisibility.shouldShowControls {
                    floatingTerminalControls
                        .padding(.bottom, 4)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .navigationBarBackButtonHidden(true)
            .toolbar {
                IOSTerminalNavigationToolbar(
                    selectedView: selectedView,
                    shouldShowViewSwitcher: shouldShowViewSwitcher,
                    selectedViewBinding: resolvedServerId.map { selectedViewBinding(for: $0) },
                    visibleTabs: viewTabConfig.currentVisibleTabs,
                    selectedServer: selectedServer,
                    onBack: {
                        dismissKeyboardForCurrentSession()
                        onBack()
                    },
                    onOpenTerminalTab: openNewTab,
                    onOpenFileTab: openNewFileTab,
                    onOpenSettings: {
                        showingSettings = true
                    },
                    onShowFind: showFindNavigatorForCurrentSession,
                    onEditServer: { server in
                        serverToEdit = server
                    },
                    onEnterZenMode: {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                            isZenModeEnabled = true
                        }
                    },
                    onDisconnect: disconnectCurrentServerSessions
                )
            }
            .toolbar(effectiveZenModeEnabled ? .hidden : .visible, for: .navigationBar)
            .animation(.spring(response: 0.28, dampingFraction: 0.84), value: floatingControlsVisibility.shouldShowControls)
            .animation(.spring(response: 0.28, dampingFraction: 0.84), value: floatingControlsVisibility.shouldShowReturnButton)
    }

    private func dismissKeyboardForCurrentSession() {
        guard let selectedId = effectiveSelectedSessionId,
              let terminal = sessionManager.peekTerminal(for: selectedId) else { return }
        terminal.dismissKeyboardForUser()
    }

    private func showKeyboardForCurrentSession() {
        guard selectedView == ConnectionViewTab.terminal.id,
              let selectedId = effectiveSelectedSessionId,
              let terminal = sessionManager.peekTerminal(for: selectedId) else { return }
        clearPendingVoiceReturn(for: selectedId)
        terminal.requestKeyboardFocus(for: .explicitUserRequest)
    }

    private func startVoiceInputForCurrentSession() {
        guard selectedView == ConnectionViewTab.terminal.id,
              terminalPreferences.terminalVoiceButtonEnabled,
              !isSelectedTerminalVoiceRecording,
              let selectedId = effectiveSelectedSessionId,
              let terminal = sessionManager.peekTerminal(for: selectedId) else { return }
        clearPendingVoiceReturn(for: selectedId)
        if terminal.triggerVoiceInput() {
            voiceRecordingBySession[selectedId] = true
        }
    }

    private func sendReturnForCurrentSession() {
        guard selectedView == ConnectionViewTab.terminal.id,
              let selectedId = effectiveSelectedSessionId,
              let terminal = sessionManager.peekTerminal(for: selectedId) else { return }
        if terminal.sendReturnKey() {
            clearPendingVoiceReturn(for: selectedId)
        }
    }

    private func clearPendingVoiceReturnForCurrentSession() {
        guard let selectedId = effectiveSelectedSessionId else { return }
        clearPendingVoiceReturn(for: selectedId)
    }

    private func clearPendingVoiceReturn(for sessionId: UUID) {
        pendingVoiceReturnBySession[sessionId] = false
    }

    private func showFindNavigatorForCurrentSession() {
        guard selectedView == ConnectionViewTab.terminal.id,
              let selectedId = effectiveSelectedSessionId,
              let terminal = sessionManager.peekTerminal(for: selectedId) else { return }
        terminal.showFindNavigator()
    }

    @ViewBuilder
    private var floatingTerminalControls: some View {
        IOSTerminalFloatingControls(
            showsReturnButton: floatingControlsVisibility.shouldShowReturnButton,
            showsVoiceButton: floatingControlsVisibility.shouldShowVoiceButton,
            colorScheme: colorScheme,
            onKeyboard: showKeyboardForCurrentSession,
            onVoiceInput: startVoiceInputForCurrentSession,
            onReturn: sendReturnForCurrentSession
        )
    }

    private func activateTerminal(_ session: ConnectionSession) {
        let terminalAlreadyExists = sessionManager.hasTerminal(for: session.id)
        switch IOSTerminalViewPolicy.terminalPreparation(
            sessionId: session.id,
            selectedViewId: selectedView,
            terminalAlreadyExists: terminalAlreadyExists,
            isTerminalAlreadyScheduled: shouldShowTerminalBySession[session.id] == true
        ) {
        case .none:
            break
        case .refreshExisting:
            refreshTerminal(for: session)
        case .markVisible:
            shouldShowTerminalBySession[session.id] = true
        }
        guard selectedView == ConnectionViewTab.terminal.id else { return }
        focusTerminal(for: session)
    }

    private func refreshTerminalAfterChromeChange() {
        guard selectedView == "terminal",
              let session = selectedSession ?? serverSessions.first else {
            return
        }

        DispatchQueue.main.async {
            refreshTerminal(for: session)
            focusTerminal(for: session)
        }
    }

    private func openNewTab() {
        guard let server = selectedServer else { return }
        guard sessionManager.canOpenNewTab else {
            showingTabLimitAlert = true
            return
        }
        sessionManager.requestConnectionOpen(
            to: server,
            forceNew: true,
            onOpened: { session in
                sessionManager.selectedViewByServer[server.id] = IOSConnectionViewSelectionPolicy.preferredConnectViewId(
                    isTerminalVisible: viewTabConfig.isTabVisible(ConnectionViewTab.terminal.id),
                    effectiveDefaultViewId: viewTabConfig.effectiveDefaultTab()
                )
                currentServerId = server.id
                shouldShowTerminalBySession[session.id] = true
                reconnectTokenBySession[session.id] = session.id
                sessionManager.selectedSessionId = session.id
            },
            onFailed: { error in
                if case VVTermError.proRequired = error {
                    showingTabLimitAlert = true
                }
            }
        )
    }

    private func openNewFileTab() {
        guard let server = selectedServer else { return }
        guard fileTabs.canOpenNewTab(for: server.id) else {
            showingFileTabLimitAlert = true
            return
        }

        let plan = RemoteFileTabOpeningPolicy.newTabPlan(
            selectedFileTab: selectedFileTab,
            selectedFileTabLastVisitedPath: selectedFileTab.flatMap { fileBrowser.lastVisitedPath(for: $0) },
            fallbackWorkingDirectory: selectedSession?.workingDirectory
        )
        let newTab = plan.sourceTab.flatMap { fileTabs.duplicateTab($0, seedPath: plan.seedPath) }
            ?? fileTabs.openTab(for: server, seedPath: plan.seedPath)

        guard let newTab else { return }
        fileBrowser.prepareNewTab(newTab, duplicating: plan.sourceTab)
        sessionManager.selectedViewByServer[server.id] = IOSConnectionViewSelectionPolicy.storedViewId(
            requestedViewId: ConnectionViewTab.files.id,
            isRequestedViewVisible: viewTabConfig.isTabVisible(ConnectionViewTab.files.id),
            effectiveDefaultViewId: viewTabConfig.effectiveDefaultTab()
        )
    }

    private func closeFileTab(_ tab: RemoteFileTab) {
        if let removedTab = fileTabs.closeTab(tab) {
            fileBrowser.removeState(for: removedTab.id)
        }
    }

    private func disconnectCurrentServerSessions() {
        guard let serverId = resolvedServerId else {
            onBack()
            return
        }
        disconnectCoordinator.requestServerDisconnect(
            serverId: serverId,
            disconnectTerminals: sessionManager.disconnectServerAndWait,
            onCompleted: {
                onBack()
            }
        )
    }

    private func synchronizeRecoveredTerminalState() {
        let recoveredState = IOSTerminalViewPolicy.recoveredTerminalState(
            canUseZenMode: canUseZenMode,
            requestedTerminalDismissal: requestedTerminalDismissal
        )
        if let shouldShowZenPanel = recoveredState.shouldShowZenPanel {
            showingZenPanel = shouldShowZenPanel
        }
        if let shouldEnableZenMode = recoveredState.isZenModeEnabled {
            isZenModeEnabled = shouldEnableZenMode
        }
        requestedTerminalDismissal = recoveredState.requestedTerminalDismissal

        guard recoveredState.shouldCallBack else { return }
        DispatchQueue.main.async {
            onBack()
        }
    }

    /// Refresh terminal display and trigger server redraw
    private func refreshTerminal(for session: ConnectionSession) {
        guard scenePhase == .active else { return }
        guard let terminal = sessionManager.peekTerminal(for: session.id) else { return }
        sessionManager.markTerminalUsed(for: session.id)

        // Resume rendering if paused
        terminal.resumeRendering()

        // Force layout + refresh after a brief delay to ensure the view is attached.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak terminal] in
            guard let terminal else { return }
            guard scenePhase == .active else { return }
            guard sessionManager.sessions.contains(where: { $0.id == session.id }) else { return }
            guard sessionManager.peekTerminal(for: session.id) === terminal else { return }
            guard terminal.window != nil else { return }

            if let nativeScrollContainer = TerminalNativeScrollContainerView.nativeScrollContainer(containing: terminal) {
                let targetSize = nativeScrollContainer.refreshTerminalViewport()
                if targetSize.width > 0, targetSize.height > 0 {
                    terminal.sizeDidChange(targetSize)
                }
            } else if let container = terminal.superview {
                container.setNeedsLayout()
                container.layoutIfNeeded()

                let targetBounds = container.bounds

                if targetBounds.width > 0, targetBounds.height > 0 {
                    if terminal.frame != targetBounds {
                        terminal.frame = targetBounds
                    }
                    terminal.sizeDidChange(targetBounds.size)
                }
            }

            terminal.forceRefresh()

            // Send resize to force server to redraw prompt
            if let size = terminal.terminalSize() {
                sessionManager.requestSessionResize(
                    TerminalResizeRequestSize(
                        cols: Int(size.columns),
                        rows: Int(size.rows)
                    ),
                    for: session.id
                )
            }
        }
    }

    private func focusTerminal(for session: ConnectionSession) {
        guard scenePhase == .active else { return }
        guard let terminal = sessionManager.peekTerminal(for: session.id) else { return }
        sessionManager.markTerminalUsed(for: session.id)

        let attemptFocus = { [weak terminal] in
            guard let terminal = terminal else { return }
            if terminal.window != nil {
                terminal.requestKeyboardFocus(for: .initialActivation)
            }
        }

        DispatchQueue.main.async {
            attemptFocus()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                attemptFocus()
            }
        }
    }

}
#endif
