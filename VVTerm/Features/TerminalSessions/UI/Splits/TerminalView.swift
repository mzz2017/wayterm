//
//  TerminalView.swift
//  VVTerm
//
//  Renders a single tab's terminal content (with optional splits).
//  Each tab is isolated - splits happen within the tab, not across tabs.
//

#if os(macOS)
import SwiftUI
import AppKit
import Foundation
import os.log

// MARK: - Terminal Tab View

/// Renders a single terminal tab with its split layout
struct TerminalTabView: View {
    let tab: TerminalTab
    let server: Server
    @ObservedObject var tabManager: TerminalTabManager
    let isSelected: Bool

    @State private var layoutVersion: Int = 0
    @State private var showingCloseConfirmation = false
    @State private var showingSplitPaneUpgradeAlert = false

    @EnvironmentObject var ghosttyApp: Ghostty.App
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(CloudKitSyncConstants.terminalThemeNameKey) private var terminalThemeName = "Aizen Dark"
    @AppStorage(CloudKitSyncConstants.terminalThemeNameLightKey) private var terminalThemeNameLight = "Aizen Light"
    @AppStorage(CloudKitSyncConstants.terminalUsePerAppearanceThemeKey) private var usePerAppearanceTheme = true
    @AppStorage("terminalVoiceButtonEnabled") private var voiceButtonEnabled = true

    @ObservedObject private var voiceInput = TerminalVoiceInputStore.shared
    @State private var showingVoiceRecording = false
    @State private var showingPermissionError = false
    @State private var permissionErrorMessage = ""
    @State private var keyMonitor: Any?

    private var voiceTarget: TerminalVoiceInputTarget {
        .pane(tab.focusedPaneId)
    }

    private var dividerColor: Color {
        ThemeColorParser.splitDividerColor(for: effectiveThemeName)
    }

    private var effectiveThemeName: String {
        guard usePerAppearanceTheme else { return terminalThemeName }
        return colorScheme == .dark ? terminalThemeName : terminalThemeNameLight
    }

    private var focusedTerminal: GhosttyTerminalView? {
        TerminalTabManager.shared.getTerminal(for: tab.focusedPaneId)
    }

    private var hasFocusedTerminal: Bool {
        focusedTerminal != nil
    }

    /// Split actions for menu commands - only active when this tab is selected
    private var splitActions: TerminalSplitActions? {
        guard isSelected else { return nil }
        return TerminalSplitActions(
            splitHorizontal: { splitHorizontal() },
            splitVertical: { splitVertical() },
            closePane: { requestClosePane() }
        )
    }

    var body: some View {
        ZStack {
            // Refresh when terminals register/unregister so overlays can update immediately.
            let _ = tabManager.terminalRegistryVersion
            if let layout = tab.layout {
                renderNode(layout)
            } else {
                // Single pane - no splits
                TerminalPaneView(
                    paneId: tab.rootPaneId,
                    server: server,
                    isFocused: true,
                    isTabSelected: isSelected,
                    onFocus: { },
                    onProcessExit: { handlePaneExit(paneId: tab.rootPaneId) },
                    showsVoiceButton: isSelected
                        && voiceButtonEnabled
                        && !showingVoiceRecording
                        && hasFocusedTerminal,
                    onVoiceTrigger: { startVoiceRecording() }
                )
            }

            if isSelected && hasFocusedTerminal {
                if showingVoiceRecording {
                    voiceOverlay
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .focusedValue(\.activeServerId, isSelected ? server.id : nil)
        .focusedValue(\.activePaneId, isSelected ? tab.focusedPaneId : nil)
        .focusedSceneValue(\.terminalSplitActions, splitActions)
        .alert("Close this terminal?", isPresented: $showingCloseConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Close", role: .destructive) {
                closeCurrentPane()
            }
            .keyboardShortcut(.defaultAction)
        } message: {
            Text("The SSH connection will be terminated.")
        }
        .alert("Voice Input Unavailable", isPresented: $showingPermissionError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(permissionErrorMessage)
        }
        .splitPaneProFeatureAlert(isPresented: $showingSplitPaneUpgradeAlert)
        .onAppear {
            updateKeyMonitor()
        }
        .onChange(of: isSelected) { _ in
            updateKeyMonitor()
            if !isSelected, showingVoiceRecording {
                cancelVoiceRecording()
            }
        }
        .onDisappear {
            cleanupKeyMonitor()
            if showingVoiceRecording {
                cancelVoiceRecording()
            }
        }
    }

    private func requestClosePane() {
        showingCloseConfirmation = true
    }

    // MARK: - Render Split Tree

    private func renderNode(_ node: TerminalSplitNode) -> AnyView {
        switch node {
        case .leaf(let paneId):
            return AnyView(
                TerminalPaneView(
                    paneId: paneId,
                    server: server,
                    isFocused: tab.focusedPaneId == paneId,
                    isTabSelected: isSelected,
                    onFocus: { focusPane(paneId) },
                    onProcessExit: { handlePaneExit(paneId: paneId) },
                    showsVoiceButton: isSelected
                        && voiceButtonEnabled
                        && !showingVoiceRecording
                        && tab.focusedPaneId == paneId
                        && hasFocusedTerminal,
                    onVoiceTrigger: { startVoiceRecording() }
                )
                .id("\(paneId)-\(layoutVersion)")
            )

        case .split(let split):
            let currentNode = node
            let ratioBinding = Binding<CGFloat>(
                get: { CGFloat(split.ratio) },
                set: { newRatio in
                    updateRatio(node: currentNode, newRatio: Double(newRatio))
                }
            )

            return AnyView(
                SplitView(
                    split.direction == .horizontal ? .horizontal : .vertical,
                    ratioBinding,
                    dividerColor: dividerColor,
                    left: { renderNode(split.left) },
                    right: { renderNode(split.right) },
                    onEqualize: { equalizeLayout() }
                )
            )
        }
    }

    // MARK: - Actions

    private func focusPane(_ paneId: UUID) {
        var updatedTab = tab
        updatedTab.focusedPaneId = paneId
        tabManager.updateTab(updatedTab)
    }

    private func updateRatio(node: TerminalSplitNode, newRatio: Double) {
        guard var layout = tab.layout else { return }
        let updated = node.withUpdatedRatio(newRatio)
        layout = layout.replacingNode(node, with: updated)
        var updatedTab = tab
        updatedTab.layout = layout
        tabManager.updateTab(updatedTab)
    }

    private func equalizeLayout() {
        guard let layout = tab.layout else { return }
        var updatedTab = tab
        updatedTab.layout = layout.equalized()
        tabManager.updateTab(updatedTab)
    }

    private func handlePaneExit(paneId: UUID) {
        tabManager.requestPaneProcessExit(forPane: paneId)
    }

    // MARK: - Split Actions

    func splitHorizontal() {
        guard StoreManager.shared.isPro else {
            showingSplitPaneUpgradeAlert = true
            return
        }
        guard tabManager.splitHorizontal(tab: tab, paneId: tab.focusedPaneId) != nil else { return }
        layoutVersion += 1
    }

    func splitVertical() {
        guard StoreManager.shared.isPro else {
            showingSplitPaneUpgradeAlert = true
            return
        }
        guard tabManager.splitVertical(tab: tab, paneId: tab.focusedPaneId) != nil else { return }
        layoutVersion += 1
    }

    func closeCurrentPane() {
        tabManager.closePane(tab: tab, paneId: tab.focusedPaneId)
    }

    // MARK: - Voice Input (macOS)

    private var voiceOverlay: some View {
        VoiceRecordingView(
            voiceInput: voiceInput,
            target: voiceTarget,
            onSend: { transcribedText in
                sendTranscriptionToTerminal(transcribedText)
                showingVoiceRecording = false
            },
            onCancel: {
                showingVoiceRecording = false
            }
        )
    }

    private func updateKeyMonitor() {
        if isSelected {
            setupKeyMonitor()
        } else {
            cleanupKeyMonitor()
        }
    }

    private func setupKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [self] event in
            handleMonitoredKeyDown(event)
        }
    }

    private func cleanupKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }

    private func handleMonitoredKeyDown(_ event: NSEvent) -> NSEvent? {
        handleVoiceShortcut(event)
    }

    private func handleVoiceShortcut(_ event: NSEvent) -> NSEvent? {
        guard isSelected else { return event }

        let keyCodeEscape: UInt16 = 53
        let keyCodeReturn: UInt16 = 36

        if showingVoiceRecording {
            if event.keyCode == keyCodeEscape {
                cancelVoiceRecording()
                return nil
            }
            if event.keyCode == keyCodeReturn {
                toggleVoiceRecording()
                return nil
            }
        }

        guard MacTerminalShortcut.toggleVoiceRecording.matches(event) else {
            return event
        }
        toggleVoiceRecording()
        return nil
    }

    private func toggleVoiceRecording() {
        if showingVoiceRecording {
            voiceInput.requestStopAndSend(
                for: voiceTarget,
                onCompleted: { text in
                    sendTranscriptionToTerminal(text)
                    showingVoiceRecording = false
                }
            )
        } else {
            startVoiceRecording()
        }
    }

    private func startVoiceRecording() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            showingVoiceRecording = true
        }
        voiceInput.requestStart(
            for: voiceTarget,
            onFailed: { message in
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    showingVoiceRecording = false
                }
                permissionErrorMessage = message
                showingPermissionError = true
            }
        )
    }

    private func cancelVoiceRecording() {
        voiceInput.requestCancel(
            for: voiceTarget,
            onCancelled: {
                showingVoiceRecording = false
            }
        )
    }

    private func sendTranscriptionToTerminal(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let terminal = focusedTerminal else { return }
        DispatchQueue.main.async {
            terminal.sendText(trimmed)
        }
    }
}

// MARK: - Terminal Pane View

/// Renders a single terminal pane (leaf in split tree)
struct TerminalPaneView: View {
    let paneId: UUID
    let server: Server
    let isFocused: Bool
    let isTabSelected: Bool
    let onFocus: () -> Void
    let onProcessExit: () -> Void
    let showsVoiceButton: Bool
    let onVoiceTrigger: () -> Void

    @EnvironmentObject var ghosttyApp: Ghostty.App
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase

    @State private var isReady = false
    @State private var credentials: ServerCredentials?
    @State private var credentialLoadErrorMessage: String?
    @State private var reconnectToken = UUID()
    @State private var showingTmuxInstallPrompt = false
    @State private var showingMoshInstallPrompt = false
    @State private var isInstallingMosh = false
    @State private var operationNotice: NoticeItem?
    @State private var dismissFallbackBanner = false
    @State private var terminalBackgroundColor: Color = Self.initialTerminalBackgroundColor()
    @State private var hasEstablishedConnection = false
    @State private var showingRetrustHostConfirmation = false
    @StateObject private var richPasteUI = TerminalRichPasteUIModel()

    @AppStorage(CloudKitSyncConstants.terminalThemeNameKey) private var terminalThemeName = "Aizen Dark"
    @AppStorage(CloudKitSyncConstants.terminalThemeNameLightKey) private var terminalThemeNameLight = "Aizen Light"
    @AppStorage(CloudKitSyncConstants.terminalUsePerAppearanceThemeKey) private var usePerAppearanceTheme = true
    @AppStorage("sshAutoReconnect") private var autoReconnectEnabled = true

    private var paneState: TerminalPaneState? {
        TerminalTabManager.shared.paneStates[paneId]
    }

    private var connectionState: ConnectionState {
        paneState?.connectionState ?? .idle
    }

    private var isHostKeyVerificationFailure: Bool {
        guard case .failed(let error) = connectionState else { return false }
        return error == SSHError.hostKeyVerificationFailed.localizedDescription
            || error.contains("Host key verification failed")
    }

    private var retrustHostConfirmationMessage: String {
        let endpoint = "\(server.host):\(server.port)"
        return String(
            format: String(localized: "VVTerm saved a different SSH host key for %@. Only continue if you recreated this server or trust the new host."),
            endpoint
        )
    }

    /// Should this pane actually have focus (both tab selected AND pane focused)
    private var shouldFocus: Bool {
        isTabSelected && isFocused
    }

    /// Check if terminal already exists (reuse case)
    private var terminalExists: Bool {
        TerminalTabManager.shared.getTerminal(for: paneId) != nil
    }

    private var effectiveThemeName: String {
        guard usePerAppearanceTheme else { return terminalThemeName }
        return colorScheme == .dark ? terminalThemeName : terminalThemeNameLight
    }

    private var fallbackBannerMessage: String? {
        guard paneState?.activeTransport == .sshFallback else { return nil }
        guard !dismissFallbackBanner else { return nil }
        return paneState?.moshFallbackReason?.bannerMessage ?? String(localized: "Using SSH fallback for this session.")
    }

    private var shouldPromptMoshInstall: Bool {
        guard server.connectionMode == .mosh else { return false }
        guard paneState?.activeTransport == .sshFallback else { return false }
        return paneState?.moshFallbackReason == .serverMissing
    }

    private var shouldShowMoshDurabilityHint: Bool {
        guard server.connectionMode == .mosh else { return false }
        return paneState?.tmuxStatus == .off
    }

    private var shouldUseInlineReconnectPresentation: Bool {
        hasEstablishedConnection && terminalExists && connectionState.isConnecting
    }

    private var noticeSurfaceStyle: NoticeSurfaceStyle {
        .terminal(backgroundColor: terminalBackgroundColor)
    }

    private var reconnectBannerMessage: String? {
        guard shouldUseInlineReconnectPresentation else { return nil }

        if case .reconnecting(let attempt) = connectionState {
            return String(format: String(localized: "Reconnecting (attempt %lld)…"), Int64(attempt))
        }

        return String(localized: "Reconnecting…")
    }

    private var topBannerNotice: NoticeItem? {
        if let reconnectBannerMessage {
            return NoticeItem(
                id: "pane-reconnect-\(paneId.uuidString)",
                lane: .topBanner,
                level: .warning,
                leading: .activity,
                message: reconnectBannerMessage
            )
        }

        if let fallbackBannerMessage {
            return NoticeItem(
                id: "pane-fallback-\(paneId.uuidString)",
                lane: .topBanner,
                level: .warning,
                leading: .icon("arrow.trianglehead.2.clockwise"),
                message: fallbackBannerMessage,
                dismissAction: { dismissFallbackBanner = true }
            )
        }

        return richPasteUI.topBannerNotice
    }

    private var bottomOperationNotice: NoticeItem? {
        if paneState?.tmuxStatus == .installing {
            return NoticeItem(
                id: "pane-tmux-install-\(paneId.uuidString)",
                lane: .bottomOperation,
                level: .info,
                leading: .activity,
                title: String(localized: "Installing tmux"),
                message: String(localized: "Preparing persistent shell support.")
            )
        }

        if isInstallingMosh {
            return NoticeItem(
                id: "pane-mosh-install-\(paneId.uuidString)",
                lane: .bottomOperation,
                level: .info,
                leading: .activity,
                title: String(localized: "Installing mosh-server"),
                message: String(localized: "Preparing the remote host for Mosh.")
            )
        }

        if let operationNotice {
            return operationNotice
        }

        return richPasteUI.bottomOperationNotice
    }

    private var voiceTriggerBottomInset: CGFloat {
        bottomOperationNotice == nil ? 0 : 104
    }

    var body: some View {
        NoticeHost(
            topBanner: topBannerNotice,
            bottomOperation: bottomOperationNotice,
            bannerSurfaceStyle: noticeSurfaceStyle,
            operationSurfaceStyle: noticeSurfaceStyle
        ) {
            ZStack {
                terminalBackgroundColor

                if ghosttyApp.readiness == .ready, let credentials = credentials {
                    SSHTerminalPaneWrapper(
                        paneId: paneId,
                        server: server,
                        credentials: credentials,
                        richPasteUIModel: richPasteUI,
                        isActive: shouldFocus,
                        onProcessExit: onProcessExit,
                        onReady: { isReady = true }
                    )
                    .id(reconnectToken)
                    .contentShape(Rectangle())
                    .onTapGesture { onFocus() }
                }

                blockingOverlay

                if showsVoiceButton && isFocused && isTabSelected && connectionState.isConnected {
                    voiceTriggerButton
                        .padding(.bottom, voiceTriggerBottomInset)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .transition(.opacity)
                }
            }
        }
        .opacity(isFocused ? 1.0 : 0.7)
        .clipped()
        .task {
            updateTerminalBackgroundColor()
            // If terminal exists, mark ready immediately
            if terminalExists {
                isReady = true
                hasEstablishedConnection = true
            }
            if connectionState.isConnected {
                hasEstablishedConnection = true
            }
            let result = await TerminalTabManager.shared.loadCredentials(for: server)
            if let loadedCredentials = result.credentials {
                credentials = loadedCredentials
                credentialLoadErrorMessage = nil
            } else if result.errorMessage != nil {
                credentialLoadErrorMessage = String(localized: "Failed to load credentials")
            }

            if paneState?.tmuxStatus == .missing {
                showingTmuxInstallPrompt = true
            }
            if shouldPromptMoshInstall {
                showingMoshInstallPrompt = true
            }
            startConnectWatchdog()
            attemptAutoReconnectIfNeeded()
        }
        .onChange(of: terminalThemeName) { _ in updateTerminalBackgroundColor() }
        .onChange(of: terminalThemeNameLight) { _ in updateTerminalBackgroundColor() }
        .onChange(of: usePerAppearanceTheme) { _ in updateTerminalBackgroundColor() }
        .onChange(of: colorScheme) { _ in updateTerminalBackgroundColor() }
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                attemptAutoReconnectIfNeeded()
            }
        }
        .onChange(of: isReady) { _ in
            startConnectWatchdog()
        }
        .onChange(of: connectionState) { state in
            if state.isConnecting || state.isConnected {
                if terminalExists {
                    hasEstablishedConnection = true
                }
                if state.isConnected {
                    hasEstablishedConnection = true
                }
                startConnectWatchdog()
            } else if case .disconnected = state {
                attemptAutoReconnectIfNeeded()
            }
        }
        .onChange(of: paneState?.tmuxStatus) { status in
            if status == .missing {
                showingTmuxInstallPrompt = true
            }
        }
        .onChange(of: paneState?.moshFallbackReason) { _ in
            if paneState?.activeTransport == .sshFallback {
                dismissFallbackBanner = false
            }
            if shouldPromptMoshInstall {
                showingMoshInstallPrompt = true
            }
        }
        .onChange(of: paneState?.activeTransport) { transport in
            dismissFallbackBanner = transport != .sshFallback ? false : dismissFallbackBanner
            if shouldPromptMoshInstall {
                showingMoshInstallPrompt = true
            }
        }
        .task(id: paneState?.activeTransport == .sshFallback ? paneState?.moshFallbackReason : nil) {
            guard paneState?.activeTransport == .sshFallback else { return }
            dismissFallbackBanner = false
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            dismissFallbackBanner = true
        }
        .alert("Install tmux?", isPresented: $showingTmuxInstallPrompt) {
            Button("Install") {
                TerminalTabManager.shared.requestTmuxInstall(for: paneId)
            }
            Button("Continue without persistence", role: .cancel) {
                disableTmuxForServer()
            }
        } message: {
            Text("tmux keeps your terminal session alive across app restarts and disconnects.")
        }
        .alert("Install mosh-server?", isPresented: $showingMoshInstallPrompt) {
            Button("Install") {
                requestMoshInstallAndReconnect()
            }
            Button("Continue with SSH", role: .cancel) {}
        } message: {
            Text("Mosh is selected for this server, but mosh-server is missing on the host.")
        }
        .alert("Replace Trusted Host?", isPresented: $showingRetrustHostConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Replace and Reconnect", role: .destructive) {
                retrustHostAndRetry()
            }
        } message: {
            Text(retrustHostConfirmationMessage)
        }
        .terminalRichPastePrompt(using: richPasteUI)
    }

    @ViewBuilder
    private var blockingOverlay: some View {
        if let credentialLoadErrorMessage {
            BlockingStatusView(surfaceStyle: noticeSurfaceStyle) {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.red)
                    Text("Connection Failed")
                        .font(.headline)
                    Text(credentialLoadErrorMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Retry") {
                        retryConnection()
                    }
                    .buttonStyle(.bordered)
                }
                .multilineTextAlignment(.center)
            }
        } else {
            switch connectionState {
            case .connecting:
                if !shouldUseInlineReconnectPresentation {
                    BlockingStatusView(showsScrim: false, surfaceStyle: noticeSurfaceStyle) {
                        VStack(spacing: 12) {
                            ProgressView()
                                .progressViewStyle(.circular)
                            Text(String(format: String(localized: "Connecting to %@..."), server.name))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 6)
                        .multilineTextAlignment(.center)
                    }
                }
            case .reconnecting:
                if !shouldUseInlineReconnectPresentation {
                    BlockingStatusView(showsScrim: false, surfaceStyle: noticeSurfaceStyle) {
                        VStack(spacing: 16) {
                            ProgressView()
                                .progressViewStyle(.circular)
                            Text("Reconnecting...")
                                .foregroundStyle(.orange)
                        }
                        .multilineTextAlignment(.center)
                    }
                }
            case .disconnected:
                BlockingStatusView(surfaceStyle: noticeSurfaceStyle) {
                    VStack(spacing: 16) {
                        Image(systemName: "bolt.slash")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("Disconnected")
                            .foregroundStyle(.secondary)
                        if paneState?.tmuxStatus.indicatesTmux == true {
                            Text("tmux session is still running on the server.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        } else if shouldShowMoshDurabilityHint {
                            Text("Without tmux, app backgrounding can interrupt running commands.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        Button("Reconnect") {
                            retryConnection()
                        }
                        .buttonStyle(.bordered)
                    }
                    .multilineTextAlignment(.center)
                }
            case .failed(let error):
                BlockingStatusView(surfaceStyle: noticeSurfaceStyle) {
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                            .foregroundStyle(.red)
                        Text("Connection Failed")
                            .font(.headline)
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if isHostKeyVerificationFailure {
                            Button("Trust New Host Key") {
                                showingRetrustHostConfirmation = true
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        Button("Retry") {
                            retryConnection()
                        }
                        .buttonStyle(.bordered)
                    }
                    .multilineTextAlignment(.center)
                }
            case .connected, .idle:
                if !isReady && !terminalExists {
                    BlockingStatusView(showsScrim: false, surfaceStyle: noticeSurfaceStyle) {
                        VStack(spacing: 12) {
                            ProgressView()
                                .progressViewStyle(.circular)
                            Text(String(format: String(localized: "Connecting to %@..."), server.name))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 6)
                        .multilineTextAlignment(.center)
                    }
                }
            }
        }
    }

    private func disableTmuxForServer() {
        TerminalTabManager.shared.disableTmux(for: server.id)
    }

    private func retrustHostAndRetry() {
        TerminalTabManager.shared.requestPaneHostRetrust(
            paneId: paneId,
            server: server,
            onCompleted: { didReconnect in
                guard didReconnect else { return }
                reconnectToken = UUID()
            }
        )
    }

    private func attemptAutoReconnectIfNeeded() {
        guard TerminalTabManager.shared.shouldAutoReconnectPane(
            paneId,
            isSceneActive: scenePhase == .active,
            autoReconnectEnabled: autoReconnectEnabled
        ) else { return }
        retryConnection()
    }

    private func retryConnection() {
        credentialLoadErrorMessage = nil
        operationNotice = nil
        isReady = false
        TerminalTabManager.shared.requestPaneRetry(
            paneId: paneId,
            server: server,
            onCompleted: { result in
                guard let loadedCredentials = result.credentials else {
                    if result.errorMessage != nil {
                        credentialLoadErrorMessage = String(localized: "Failed to load credentials")
                    }
                    return
                }
                credentials = loadedCredentials
                credentialLoadErrorMessage = nil
                reconnectToken = UUID()
                startConnectWatchdog()
            }
        )
    }

    private func startConnectWatchdog() {
        TerminalTabManager.shared.scheduleConnectWatchdog(
            forPaneId: paneId,
            isReady: isReady,
            terminalExists: terminalExists,
            timeoutMessage: String(localized: "Connection timed out. Please retry.")
        ) {
            retryConnection()
        }
    }

    private func requestMoshInstallAndReconnect() {
        guard !isInstallingMosh else { return }
        isInstallingMosh = true
        operationNotice = nil

        TerminalTabManager.shared.requestMoshInstallAndReconnect(
            for: paneId,
            onCompleted: {
                isInstallingMosh = false
                operationNotice = nil
                reconnectToken = UUID()
            },
            onFailed: { error in
                isInstallingMosh = false
                operationNotice = NoticeItem(
                    id: "pane-mosh-install-error-\(paneId.uuidString)",
                    lane: .bottomOperation,
                    level: .error,
                    leading: .icon("xmark.octagon.fill"),
                    title: String(localized: "mosh-server install failed"),
                    message: error.localizedDescription,
                    dismissAction: { operationNotice = nil }
                )
            }
        )
    }

    private func updateTerminalBackgroundColor() {
        let themeName = effectiveThemeName
        Task.detached(priority: .utility) {
            let resolved = ThemeColorParser.backgroundColor(for: themeName)!
            await MainActor.run {
                terminalBackgroundColor = resolved
                UserDefaults.standard.set(resolved.toHex(), forKey: "terminalBackgroundColor")
            }
        }
    }

    private static func initialTerminalBackgroundColor() -> Color {
        let defaults = UserDefaults.standard

        if let cachedHex = defaults.string(forKey: "terminalBackgroundColor") {
            return Color.fromHex(cachedHex)
        }

        let usePerAppearanceTheme = defaults.object(forKey: CloudKitSyncConstants.terminalUsePerAppearanceThemeKey) as? Bool ?? true
        let darkThemeName = defaults.string(forKey: CloudKitSyncConstants.terminalThemeNameKey) ?? "Aizen Dark"
        let lightThemeName = defaults.string(forKey: CloudKitSyncConstants.terminalThemeNameLightKey) ?? "Aizen Light"
        let isDarkAppearance = NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let themeName = usePerAppearanceTheme ? (isDarkAppearance ? darkThemeName : lightThemeName) : darkThemeName

        return ThemeColorParser.backgroundColor(for: themeName)!
    }

    private var voiceTriggerButton: some View {
        Button {
            onVoiceTrigger()
        } label: {
            Image(systemName: "mic.fill")
                .font(.system(size: 16, weight: .semibold))
                .padding(10)
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .help(Text("Voice input (Command+Shift+M)"))
        .padding(14)
    }
}

// MARK: - SSH Terminal Pane Wrapper

/// Wraps SSH connection and Ghostty terminal for a pane
struct SSHTerminalPaneWrapper: NSViewRepresentable {
    let paneId: UUID
    let server: Server
    let credentials: ServerCredentials
    let richPasteUIModel: TerminalRichPasteUIModel
    let isActive: Bool
    let onProcessExit: () -> Void
    let onReady: () -> Void

    @EnvironmentObject var ghosttyApp: Ghostty.App

    private var surfaceAttachContext: TerminalSurfaceAttachContext {
        TerminalSurfaceAttachContext(
            isAppActive: true,
            isViewActive: isActive,
            autoReconnectEnabled: true
        )
    }

    func makeNSView(context: Context) -> NSView {
        // Ensure Ghostty app is ready
        guard let app = ghosttyApp.app else {
            return NSView(frame: .zero)
        }

        let coordinator = context.coordinator
        TerminalTabManager.shared.configureRuntime(
            forPane: paneId,
            server: server,
            credentials: credentials,
            onProcessExit: onProcessExit
        )

        // Check if terminal already exists for this pane (reuse to save memory)
        if let existingTerminal = TerminalTabManager.shared.getTerminal(for: paneId) {
            coordinator.isReusingTerminal = true
            coordinator.terminal = existingTerminal

            existingTerminal.onResize = { [paneId] cols, rows in
                TerminalTabManager.shared.requestPaneResize(
                    TerminalResizeRequestSize(cols: cols, rows: rows),
                    forPane: paneId
                )
            }
            existingTerminal.onPwdChange = { [paneId] rawDirectory in
                TerminalTabManager.shared.updatePaneWorkingDirectory(paneId, rawDirectory: rawDirectory)
            }
            existingTerminal.onTitleChange = { [paneId] title in
                TerminalTabManager.shared.updatePaneTitle(paneId, rawTitle: title)
            }
            existingTerminal.onZoomAction = { [paneId] action in
                TerminalTabManager.shared.handleTerminalZoom(action, for: paneId)
            }
            existingTerminal.applyPresentationOverrides(TerminalTabManager.shared.presentationOverrides(for: paneId))
            existingTerminal.writeCallback = { [paneId] data in
                TerminalTabManager.shared.requestPaneInput(data, toPane: paneId)
            }
            coordinator.installRichPasteInterception(on: existingTerminal)

            // Re-wrap in scroll view
            let scrollView = TerminalScrollView(
                contentSize: NSSize(width: 800, height: 600),
                surfaceView: existingTerminal
            )

            DispatchQueue.main.async {
                onReady()
                coordinator.attachSurface(existingTerminal, context: surfaceAttachContext)
            }

            return scrollView
        }

        // Create Ghostty terminal with custom I/O for SSH
        let terminalView = GhosttyTerminalView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600),
            worktreePath: NSHomeDirectory(),
            ghosttyApp: app,
            appWrapper: ghosttyApp,
            paneId: paneId.uuidString,
            useCustomIO: true
        )

        terminalView.onReady = { [weak coordinator, weak terminalView] in
            onReady()
            if let terminalView = terminalView {
                coordinator?.attachSurface(terminalView, context: surfaceAttachContext)
            }
        }
        terminalView.onProcessExit = onProcessExit
        terminalView.onPwdChange = { [paneId] rawDirectory in
            TerminalTabManager.shared.updatePaneWorkingDirectory(paneId, rawDirectory: rawDirectory)
        }
        terminalView.onTitleChange = { [paneId] title in
            TerminalTabManager.shared.updatePaneTitle(paneId, rawTitle: title)
        }
        terminalView.onZoomAction = { [paneId] action in
            TerminalTabManager.shared.handleTerminalZoom(action, for: paneId)
        }
        terminalView.applyPresentationOverrides(TerminalTabManager.shared.presentationOverrides(for: paneId))

        // Store terminal reference
        coordinator.terminal = terminalView
        coordinator.installRichPasteInterception(on: terminalView)
        TerminalTabManager.shared.registerTerminal(terminalView, for: paneId)

        // Setup write callback to send keyboard input to SSH
        terminalView.writeCallback = { [weak coordinator] data in
            coordinator?.sendToSSH(data)
        }

        // Setup resize callback to notify SSH of terminal size changes
        terminalView.onResize = { [paneId] cols, rows in
            TerminalTabManager.shared.requestPaneResize(
                TerminalResizeRequestSize(cols: cols, rows: rows),
                forPane: paneId
            )
        }

        // Wrap in scroll view
        let scrollView = TerminalScrollView(
            contentSize: NSSize(width: 800, height: 600),
            surfaceView: terminalView
        )

        return scrollView
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let scrollView = nsView as? TerminalScrollView {
            scrollView.shouldOwnFirstResponder = isActive
            let terminalView = scrollView.surfaceView
            if terminalView.surfacePresentationOverrides != TerminalTabManager.shared.presentationOverrides(for: paneId) {
                terminalView.applyPresentationOverrides(TerminalTabManager.shared.presentationOverrides(for: paneId))
            }
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        let paneStillExists = TerminalTabManager.shared.paneStates[coordinator.paneId] != nil

        if paneStillExists {
            if let scrollView = nsView as? TerminalScrollView {
                scrollView.surfaceView.pauseRendering()
            }
            coordinator.isReusingTerminal = true
            TerminalTabManager.shared.detachSurfaceForPaneViewDisappeared(coordinator.paneId)
            return
        }

        coordinator.terminal = nil
        TerminalTabManager.shared.detachSurfaceForClosedPane(coordinator.paneId)
    }

    func makeCoordinator() -> Coordinator {
        return Coordinator(
            paneId: paneId,
            onProcessExit: onProcessExit,
            richPasteUIModel: richPasteUIModel
        )
    }

    @MainActor
    class Coordinator {
        let paneId: UUID
        let onProcessExit: () -> Void
        weak var terminal: GhosttyTerminalView?
        var isReusingTerminal = false
        private let richPasteRuntime: TerminalRichPasteRuntime

        @MainActor
        init(
            paneId: UUID,
            onProcessExit: @escaping () -> Void,
            richPasteUIModel: TerminalRichPasteUIModel
        ) {
            self.paneId = paneId
            self.onProcessExit = onProcessExit
            self.richPasteRuntime = .terminalPane(
                paneId: paneId,
                uiModel: richPasteUIModel
            )
        }

        @MainActor
        func installRichPasteInterception(on terminal: GhosttyTerminalView) {
            richPasteRuntime.install(on: terminal)
        }

        func sendToSSH(_ data: Data) {
            TerminalTabManager.shared.requestPaneInput(data, toPane: paneId)
        }

        @MainActor
        func attachSurface(_ terminal: GhosttyTerminalView, context: TerminalSurfaceAttachContext) {
            TerminalTabManager.shared.requestSurfaceAttach(
                paneId: paneId,
                terminal: terminal,
                context: context
            )
        }

        @MainActor
        func cancelShell() {
            TerminalTabManager.shared.detachSurfaceForClosedPane(paneId)
            terminal = nil
        }
    }
}

#endif
