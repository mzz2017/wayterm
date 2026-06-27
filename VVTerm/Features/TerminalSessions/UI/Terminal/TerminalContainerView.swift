//
//  TerminalContainerView.swift
//  VVTerm
//

import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

// MARK: - Terminal Container View

struct TerminalContainerView: View {
    let session: ConnectionSession
    let server: Server?
    var isActive: Bool = true
    var onVoiceRecordingChange: ((Bool) -> Void)? = nil
    var onVoiceTranscriptionSent: (() -> Void)? = nil
    private let sessionManager: ConnectionSessionManager
    @EnvironmentObject var ghosttyApp: Ghostty.App
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @State private var isReady = false
    @State private var credentialLoadErrorMessage: String?
    @State private var credentials: ServerCredentials?
    @State private var reconnectToken = UUID()
    @State private var showingTmuxInstallPrompt = false
    @State private var showingMoshInstallPrompt = false
    @State private var isInstallingMosh = false
    @State private var operationNotice: NoticeItem?
    @State private var dismissFallbackBanner = false
    @State private var hasEstablishedConnection = false
    @State private var showingRetrustHostConfirmation = false
    @StateObject private var richPasteUI = TerminalRichPasteUIModel()
    @AppStorage("sshAutoReconnect") private var autoReconnectEnabled = true

    /// Check if terminal already exists (was previously created)
    private var terminalAlreadyExists: Bool {
        sessionManager.hasTerminal(for: session.id)
    }

    // Voice input state
    #if os(macOS) || os(iOS)
    @ObservedObject private var voiceInput = TerminalVoiceInputStore.shared
    @State private var showingVoiceRecording = false
    @State private var showingPermissionError = false
    @State private var permissionErrorMessage = ""
    @AppStorage("terminalVoiceButtonEnabled") private var voiceButtonEnabled = true

    private var voiceTarget: TerminalVoiceInputTarget {
        .session(session.id)
    }
    #endif

    #if os(macOS)
    @State private var keyMonitor: Any?
    #endif

    /// Terminal background color from theme
    @State private var terminalBackgroundColor: Color = Self.initialTerminalBackgroundColor()

    /// Theme name from settings
    @AppStorage(CloudKitSyncConstants.terminalThemeNameKey) private var terminalThemeName = "Aizen Dark"
    @AppStorage(CloudKitSyncConstants.terminalThemeNameLightKey) private var terminalThemeNameLight = "Aizen Light"
    @AppStorage(CloudKitSyncConstants.terminalUsePerAppearanceThemeKey) private var usePerAppearanceTheme = true

    @MainActor
    init(
        session: ConnectionSession,
        server: Server?,
        isActive: Bool = true,
        onVoiceRecordingChange: ((Bool) -> Void)? = nil,
        onVoiceTranscriptionSent: (() -> Void)? = nil
    ) {
        self.init(
            session: session,
            server: server,
            sessionManager: ConnectionSessionManager.shared,
            isActive: isActive,
            onVoiceRecordingChange: onVoiceRecordingChange,
            onVoiceTranscriptionSent: onVoiceTranscriptionSent
        )
    }

    init(
        session: ConnectionSession,
        server: Server?,
        sessionManager: ConnectionSessionManager,
        isActive: Bool = true,
        onVoiceRecordingChange: ((Bool) -> Void)? = nil,
        onVoiceTranscriptionSent: (() -> Void)? = nil
    ) {
        self.session = session
        self.server = server
        self.sessionManager = sessionManager
        self.isActive = isActive
        self.onVoiceRecordingChange = onVoiceRecordingChange
        self.onVoiceTranscriptionSent = onVoiceTranscriptionSent
    }

    private var effectiveThemeName: String {
        guard usePerAppearanceTheme else { return terminalThemeName }
        return colorScheme == .dark ? terminalThemeName : terminalThemeNameLight
    }

    private var fallbackBannerMessage: String? {
        TerminalContainerPresentationPolicy.fallbackBannerMessage(activeTransport: session.activeTransport, fallbackReason: session.moshFallbackReason, isDismissed: dismissFallbackBanner)
    }

    private var shouldPromptMoshInstall: Bool {
        TerminalContainerPresentationPolicy.shouldPromptMoshInstall(serverConnectionMode: server?.connectionMode, activeTransport: session.activeTransport, fallbackReason: session.moshFallbackReason)
    }

    private var shouldShowMoshDurabilityHint: Bool {
        TerminalContainerPresentationPolicy.shouldShowMoshDurabilityHint(serverConnectionMode: server?.connectionMode, tmuxStatus: session.tmuxStatus)
    }

    private var shouldAllowTerminalInteraction: Bool {
        TerminalContainerPresentationPolicy.shouldAllowTerminalInteraction(connectionState: session.connectionState)
    }

    private var shouldUseInlineReconnectPresentation: Bool {
        TerminalContainerPresentationPolicy.shouldUseInlineReconnectPresentation(hasEstablishedConnection: hasEstablishedConnection, terminalAlreadyExists: terminalAlreadyExists, connectionState: session.connectionState)
    }

    private var noticeSurfaceStyle: NoticeSurfaceStyle {
        .terminal(backgroundColor: terminalBackgroundColor)
    }

    private var connectionState: ConnectionState {
        session.connectionState
    }

    private var isHostKeyVerificationFailure: Bool {
        TerminalContainerPresentationPolicy.isHostKeyVerificationFailure(connectionState: connectionState)
    }

    private var retrustHostConfirmationMessage: String {
        guard let server else {
            return String(localized: "VVTerm will forget the saved SSH host key and reconnect.")
        }
        let endpoint = "\(server.host):\(server.port)"
        return String(
            format: String(localized: "VVTerm saved a different SSH host key for %@. Only continue if you recreated this server or trust the new host."),
            endpoint
        )
    }

    private var shouldAttemptConnection: Bool {
        TerminalContainerPresentationPolicy.shouldAttemptConnection(terminalAlreadyExists: terminalAlreadyExists, connectionState: connectionState)
    }

    private var shouldShowInitializing: Bool {
        TerminalContainerPresentationPolicy.shouldShowInitializing(credentialLoadErrorMessage: credentialLoadErrorMessage, terminalAlreadyExists: terminalAlreadyExists, connectionState: connectionState, isGhosttyReady: ghosttyApp.readiness == .ready, isTerminalReady: isReady)
    }

    private var shouldShowInitializingOverlay: Bool {
        TerminalContainerPresentationPolicy.shouldShowInitializingOverlay(shouldShowInitializing: shouldShowInitializing, hasServer: server != nil, hasCredentials: credentials != nil)
    }

    #if os(macOS) || os(iOS)
    private var voiceTriggerHandler: (() -> Void)? {
        voiceButtonEnabled ? { handleVoiceTrigger() } : nil
    }
    #endif

    private var reconnectBannerMessage: String? {
        TerminalContainerPresentationPolicy.reconnectBannerMessage(
            shouldUseInlineReconnectPresentation: shouldUseInlineReconnectPresentation,
            connectionState: connectionState
        )
    }

    private var topBannerNotice: NoticeItem? {
        if let reconnectBannerMessage {
            return NoticeItem(
                id: "terminal-reconnect-\(session.id.uuidString)",
                lane: .topBanner,
                level: .warning,
                leading: .activity,
                message: reconnectBannerMessage
            )
        }

        if let fallbackBannerMessage {
            return NoticeItem(
                id: "terminal-fallback-\(session.id.uuidString)",
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
        if session.tmuxStatus == .installing {
            return NoticeItem(
                id: "terminal-tmux-install-\(session.id.uuidString)",
                lane: .bottomOperation,
                level: .info,
                leading: .activity,
                title: String(localized: "Installing tmux"),
                message: String(localized: "Preparing persistent shell support.")
            )
        }

        if isInstallingMosh {
            return NoticeItem(
                id: "terminal-mosh-install-\(session.id.uuidString)",
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

    private var voiceOverlayBottomInset: CGFloat {
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
                terminalBackgroundLayer
                terminalSurfaceLayer
                TerminalContainerStateOverlay(
                    isTerminalInitializationFailed: ghosttyApp.readiness == .error,
                    shouldShowInitializingOverlay: shouldShowInitializingOverlay,
                    shouldShowStateOverlay: ghosttyApp.readiness != .error && !shouldShowInitializingOverlay,
                    surfaceStyle: noticeSurfaceStyle,
                    credentialLoadErrorMessage: credentialLoadErrorMessage,
                    connectionState: connectionState,
                    shouldUseInlineReconnectPresentation: shouldUseInlineReconnectPresentation,
                    tmuxStatus: session.tmuxStatus,
                    shouldShowMoshDurabilityHint: shouldShowMoshDurabilityHint,
                    isHostKeyVerificationFailure: isHostKeyVerificationFailure,
                    onRetry: { retryConnection() },
                    onTrustNewHostKey: { showingRetrustHostConfirmation = true }
                )
                #if os(macOS) || os(iOS)
                TerminalContainerVoiceOverlayLayer(
                    voiceInput: voiceInput,
                    target: voiceTarget,
                    isConnected: session.connectionState.isConnected,
                    isReady: isReady,
                    isRecording: showingVoiceRecording,
                    isVoiceButtonEnabled: voiceButtonEnabled,
                    bottomInset: voiceOverlayBottomInset,
                    onStart: { startVoiceRecording() },
                    onSend: { transcribedText in
                        handleVoiceTranscription(transcribedText)
                        showingVoiceRecording = false
                    },
                    onCancel: {
                        showingVoiceRecording = false
                    }
                )
                #endif
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            requestCredentialLoadIfNeeded(force: true)
        }
        .onChange(of: server?.id) { _ in
            credentials = nil
            credentialLoadErrorMessage = nil
            requestCredentialLoadIfNeeded(force: true)
        }
        .onAppear {
            updateTerminalBackgroundColor()
            if terminalAlreadyExists {
                hasEstablishedConnection = true
            }
            if session.connectionState.isConnected {
                hasEstablishedConnection = true
            }
            if session.tmuxStatus == .missing {
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
        .onChange(of: scenePhase) { newPhase in
            if newPhase == .active {
                updateTerminalBackgroundColor()
                attemptAutoReconnectIfNeeded()
            }
        }
        .onChange(of: isReady) { _ in
            startConnectWatchdog()
        }
        .onChange(of: session.connectionState) { state in
            if state.isConnecting || state.isConnected {
                if terminalAlreadyExists {
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
        .onChange(of: session.tmuxStatus) { status in
            if status == .missing {
                showingTmuxInstallPrompt = true
            }
        }
        .onChange(of: session.moshFallbackReason) { _ in
            if session.activeTransport == .sshFallback {
                dismissFallbackBanner = false
            }
            if shouldPromptMoshInstall {
                showingMoshInstallPrompt = true
            }
        }
        .onChange(of: session.activeTransport) { transport in
            dismissFallbackBanner = transport != .sshFallback ? false : dismissFallbackBanner
            if shouldPromptMoshInstall {
                showingMoshInstallPrompt = true
            }
        }
        .task(id: session.activeTransport == .sshFallback ? session.moshFallbackReason : nil) {
            guard session.activeTransport == .sshFallback else { return }
            dismissFallbackBanner = false
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            dismissFallbackBanner = true
        }
        .terminalRichPastePrompt(using: richPasteUI)
        #if os(macOS) || os(iOS)
        .alert("Voice Input Unavailable", isPresented: $showingPermissionError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(permissionErrorMessage)
        }
        .onChange(of: showingVoiceRecording) { isRecording in
            onVoiceRecordingChange?(isRecording)
        }
        #endif
        .alert("Install tmux?", isPresented: $showingTmuxInstallPrompt) {
            Button("Install") {
                sessionManager.requestTmuxInstall(for: session.id)
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
        #if os(macOS)
        .onAppear {
            setupKeyMonitor()
        }
        .onDisappear {
            cleanupKeyMonitor()
            if showingVoiceRecording {
                cancelVoiceRecording()
            }
            onVoiceRecordingChange?(false)
        }
        #endif
        #if os(iOS)
        .onDisappear {
            if showingVoiceRecording {
                cancelVoiceRecording()
            }
            onVoiceRecordingChange?(false)
        }
        #endif
    }

    @ViewBuilder
    private var terminalBackgroundLayer: some View {
        #if os(iOS)
        terminalBackgroundColor
        #else
        terminalBackgroundColor.ignoresSafeArea()
        #endif
    }

    @ViewBuilder
    private var terminalSurfaceLayer: some View {
        if shouldAttemptConnection {
            Color.clear
                .onAppear {
                    ghosttyApp.startIfNeeded()
                }

            if let server, let credentials {
                if ghosttyApp.readiness == .ready {
                    terminalWrapperView(server: server, credentials: credentials)
                    .allowsHitTesting(shouldAllowTerminalInteraction)
                    .id(reconnectToken)
                    .onAppear {
                        if terminalAlreadyExists {
                            isReady = true
                        }
                        #if os(macOS)
                        sessionManager.peekTerminal(for: session.id)?.resumeRendering()
                        #endif
                    }
                    #if os(macOS)
                    .onDisappear {
                        sessionManager.peekTerminal(for: session.id)?.pauseRendering()
                    }
                    #endif
                }

            }
        }
    }

    @ViewBuilder
    private func terminalWrapperView(server: Server, credentials: ServerCredentials) -> some View {
        #if os(iOS)
        SSHTerminalWrapper(
            session: session,
            server: server,
            credentials: credentials,
            richPasteUIModel: richPasteUI,
            sessionManager: sessionManager,
            isActive: isActive,
            shouldPreserveKeyboardDuringReconnect: true,
            onProcessExit: {
                sessionManager.requestSessionProcessExit(forSession: session.id)
            },
            onReady: {
                isReady = true
            },
            onVoiceTrigger: voiceTriggerHandler
        )
        #else
        SSHTerminalWrapper(
            session: session,
            server: server,
            credentials: credentials,
            richPasteUIModel: richPasteUI,
            sessionManager: sessionManager,
            isActive: isActive,
            onProcessExit: {
                sessionManager.requestSessionProcessExit(forSession: session.id)
            },
            onReady: {
                isReady = true
            },
            onVoiceTrigger: voiceTriggerHandler
        )
        #endif
    }

    private func updateTerminalBackgroundColor() {
        let resolved = TerminalThemeBackgroundResolver.resolve(
            themeName: effectiveThemeName,
            fallbackHex: terminalBackgroundFallbackHex
        )
        terminalBackgroundColor = resolved.usedFallback ? Self.platformFallbackBackgroundColor() : resolved.color
        TerminalThemeBackgroundResolver.cacheResolvedBackground(resolved)
    }

    private static func initialTerminalBackgroundColor() -> Color {
        if let cached = TerminalThemeBackgroundResolver.cachedBackground() {
            return cached.color
        }
        return platformFallbackBackgroundColor()
    }

    private var terminalBackgroundFallbackHex: String {
        colorScheme == .dark ? "#000000" : "#FFFFFF"
    }

    private static func platformFallbackBackgroundColor() -> Color {
        #if os(iOS)
        return Color(UIColor.systemBackground)
        #elseif os(macOS)
        return Color(NSColor.windowBackgroundColor)
        #else
        return .black
        #endif
    }

    private func disableTmuxForServer() {
        guard let server else { return }
        sessionManager.disableTmux(for: server.id)
    }

    private func retrustHostAndRetry() {
        guard let server else { return }
        sessionManager.requestSessionHostRetrust(
            session: session,
            server: server,
            onCompleted: { didReconnect in
                guard didReconnect else { return }
                reconnectToken = UUID()
            }
        )
    }

    private func attemptAutoReconnectIfNeeded() {
        guard sessionManager.shouldAutoReconnectSession(
            session.id,
            isSceneActive: scenePhase == .active,
            autoReconnectEnabled: autoReconnectEnabled
        ) else { return }
        retryConnection()
    }

    private func startConnectWatchdog() {
        sessionManager.scheduleConnectWatchdog(
            forSessionId: session.id,
            isReady: isReady,
            terminalExists: terminalAlreadyExists,
            timeoutMessage: String(localized: "Connection timed out. Please retry.")
        ) {
            retryConnection()
        }
    }

    private func retryConnection() {
        isReady = false
        operationNotice = nil
        sessionManager.requestSessionRetry(
            session: session,
            server: server,
            onCompleted: { result in
                guard let loadedCredentials = result.credentials else {
                    if let message = result.errorMessage {
                        credentialLoadErrorMessage = String(
                            format: String(localized: "Failed to load credentials: %@"),
                            message
                        )
                    }
                    return
                }
                credentials = loadedCredentials
                credentialLoadErrorMessage = nil
                ghosttyApp.startIfNeeded()
                startConnectWatchdog()
                reconnectToken = UUID()
            }
        )
    }

    private func requestMoshInstallAndReconnect() {
        guard !isInstallingMosh else { return }
        isInstallingMosh = true
        operationNotice = nil

        sessionManager.requestMoshInstallAndReconnect(
            session: session,
            onCompleted: {
                isInstallingMosh = false
                operationNotice = nil
                reconnectToken = UUID()
            },
            onFailed: { error in
                isInstallingMosh = false
                operationNotice = NoticeItem(
                    id: "terminal-mosh-install-error-\(session.id.uuidString)",
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

    @MainActor
    private func requestCredentialLoadIfNeeded(force: Bool) {
        guard let server else { return }
        if !force, credentials != nil { return }
        let serverId = server.id
        sessionManager.requestSessionCredentialLoad(
            session: session,
            server: server,
            onCompleted: { result in
                guard self.server?.id == serverId else { return }
                if let loadedCredentials = result.credentials {
                    credentials = loadedCredentials
                    credentialLoadErrorMessage = nil
                } else if let message = result.errorMessage {
                    credentialLoadErrorMessage = String(
                        format: String(localized: "Failed to load credentials: %@"),
                        message
                    )
                }
            }
        )
    }

    // MARK: - Voice Input (macOS / iOS)

    #if os(macOS)
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
    #endif

    #if os(macOS) || os(iOS)
    private func toggleVoiceRecording() {
        if showingVoiceRecording {
            voiceInput.requestStopAndSend(
                for: voiceTarget,
                onCompleted: { text in
                    handleVoiceTranscription(text)
                    showingVoiceRecording = false
                }
            )
        } else {
            startVoiceRecording()
        }
    }
    #endif

    #if os(macOS) || os(iOS)
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
    #endif

    #if os(macOS) || os(iOS)
    private func handleVoiceTrigger() {
        guard session.connectionState.isConnected, isReady else { return }
        guard !showingVoiceRecording else { return }
        startVoiceRecording()
    }
    #endif

    private func handleVoiceTranscription(_ text: String) {
        if sendTranscriptionToTerminal(text) {
            onVoiceTranscriptionSent?()
        }
    }

    @discardableResult
    private func sendTranscriptionToTerminal(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        sessionManager.sendText(trimmed, to: session.id)
        return true
    }

}
