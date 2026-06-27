//
//  TerminalPaneView.swift
//  VVTerm
//
//  Renders a single terminal pane leaf in a split terminal tab.
//

#if os(macOS)
import SwiftUI
import AppKit
import Foundation

struct TerminalPaneView: View {
    let paneId: UUID
    let server: Server
    let tabManager: TerminalTabManager
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
        tabManager.paneStates[paneId]
    }

    private var connectionState: ConnectionState {
        paneState?.connectionState ?? .idle
    }

    private var isHostKeyVerificationFailure: Bool {
        TerminalContainerPresentationPolicy.isHostKeyVerificationFailure(connectionState: connectionState)
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
        tabManager.getTerminal(for: paneId) != nil
    }

    private var effectiveThemeName: String {
        guard usePerAppearanceTheme else { return terminalThemeName }
        return colorScheme == .dark ? terminalThemeName : terminalThemeNameLight
    }

    private var fallbackBannerMessage: String? {
        TerminalContainerPresentationPolicy.fallbackBannerMessage(
            activeTransport: paneState?.activeTransport ?? .ssh,
            fallbackReason: paneState?.moshFallbackReason,
            isDismissed: dismissFallbackBanner
        )
    }

    private var shouldPromptMoshInstall: Bool {
        TerminalContainerPresentationPolicy.shouldPromptMoshInstall(
            serverConnectionMode: server.connectionMode,
            activeTransport: paneState?.activeTransport ?? .ssh,
            fallbackReason: paneState?.moshFallbackReason
        )
    }

    private var shouldShowMoshDurabilityHint: Bool {
        TerminalContainerPresentationPolicy.shouldShowMoshDurabilityHint(
            serverConnectionMode: server.connectionMode,
            tmuxStatus: paneState?.tmuxStatus ?? .unknown
        )
    }

    private var shouldUseInlineReconnectPresentation: Bool {
        TerminalContainerPresentationPolicy.shouldUseInlineReconnectPresentation(
            hasEstablishedConnection: hasEstablishedConnection,
            terminalAlreadyExists: terminalExists,
            connectionState: connectionState
        )
    }

    private var noticeSurfaceStyle: NoticeSurfaceStyle {
        .terminal(backgroundColor: terminalBackgroundColor)
    }

    private var reconnectBannerMessage: String? {
        TerminalContainerPresentationPolicy.reconnectBannerMessage(
            shouldUseInlineReconnectPresentation: shouldUseInlineReconnectPresentation,
            connectionState: connectionState
        )
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
                        tabManager: tabManager,
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
            requestCredentialLoad()

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
                tabManager.requestTmuxInstall(for: paneId)
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
        tabManager.disableTmux(for: server.id)
    }

    private func retrustHostAndRetry() {
        tabManager.requestPaneHostRetrust(
            paneId: paneId,
            server: server,
            onCompleted: { didReconnect in
                guard didReconnect else { return }
                reconnectToken = UUID()
            }
        )
    }

    private func attemptAutoReconnectIfNeeded() {
        guard tabManager.shouldAutoReconnectPane(
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
        tabManager.requestPaneRetry(
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

    private func requestCredentialLoad() {
        let serverId = server.id
        tabManager.requestPaneCredentialLoad(
            paneId: paneId,
            server: server,
            onCompleted: { result in
                guard tabManager.paneStates[paneId]?.serverId == serverId else { return }
                if let loadedCredentials = result.credentials {
                    credentials = loadedCredentials
                    credentialLoadErrorMessage = nil
                } else if result.errorMessage != nil {
                    credentialLoadErrorMessage = String(localized: "Failed to load credentials")
                }
            }
        )
    }

    private func startConnectWatchdog() {
        tabManager.scheduleConnectWatchdog(
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

        tabManager.requestMoshInstallAndReconnect(
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
        let resolved = TerminalThemeBackgroundResolver.resolve(
            themeName: effectiveThemeName,
            fallbackHex: terminalBackgroundFallbackHex
        )
        terminalBackgroundColor = resolved.usedFallback ? Self.platformFallbackBackgroundColor() : resolved.color
        TerminalThemeBackgroundResolver.cacheResolvedBackground(resolved)
    }

    private static func initialTerminalBackgroundColor() -> Color {
        let defaults = UserDefaults.standard

        if let cached = TerminalThemeBackgroundResolver.cachedBackground(defaults: defaults) {
            return cached.color
        }

        let usePerAppearanceTheme = defaults.object(forKey: CloudKitSyncConstants.terminalUsePerAppearanceThemeKey) as? Bool ?? true
        let darkThemeName = defaults.string(forKey: CloudKitSyncConstants.terminalThemeNameKey) ?? "Aizen Dark"
        let lightThemeName = defaults.string(forKey: CloudKitSyncConstants.terminalThemeNameLightKey) ?? "Aizen Light"
        let isDarkAppearance = NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let themeName = usePerAppearanceTheme ? (isDarkAppearance ? darkThemeName : lightThemeName) : darkThemeName

        let resolved = TerminalThemeBackgroundResolver.resolve(
            themeName: themeName,
            fallbackHex: isDarkAppearance ? "#000000" : "#FFFFFF"
        )
        return resolved.usedFallback ? platformFallbackBackgroundColor() : resolved.color
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

#endif
