import SwiftUI
#if os(iOS)

struct IOSTerminalSessionPage: View {
    let session: ConnectionSession
    @ObservedObject var serverManager: ServerManager
    @ObservedObject var sessionManager: ConnectionSessionManager
    @ObservedObject var viewTabConfig: ViewTabConfigurationManager
    @ObservedObject var fileTabs: RemoteFileTabManager
    let fileBrowser: RemoteFileBrowserStore
    let selectedFileTab: RemoteFileTab?
    @Binding var shouldShowTerminalBySession: [UUID: Bool]
    @Binding var voiceRecordingBySession: [UUID: Bool]
    @Binding var pendingVoiceReturnBySession: [UUID: Bool]
    let reconnectToken: UUID
    let onActivateTerminal: (ConnectionSession) -> Void
    let onRefreshTerminal: (ConnectionSession) -> Void
    let onFocusTerminal: (ConnectionSession) -> Void
    let onEnsureInitialFileTab: () -> Void

    private var server: Server? {
        serverManager.servers.first { $0.id == session.serverId }
    }

    private var viewSelection: String {
        sessionManager.selectedViewByServer[session.serverId] ?? viewTabConfig.effectiveDefaultTab()
    }

    private var effectiveViewSelection: String {
        viewTabConfig.effectiveView(for: viewSelection)
    }

    private var terminalAlreadyExists: Bool {
        sessionManager.hasTerminal(for: session.id)
    }

    private var shouldShowTerminal: Bool {
        shouldShowTerminalBySession[session.id] ?? false
    }

    var body: some View {
        ZStack {
            if shouldShowTerminal || terminalAlreadyExists {
                TerminalContainerView(
                    session: session,
                    server: server,
                    sessionManager: sessionManager,
                    isActive: effectiveViewSelection == ConnectionViewTab.terminal.id,
                    onVoiceRecordingChange: updateVoiceRecording,
                    onVoiceTranscriptionSent: markPendingReturnIfNeeded
                )
                .id(reconnectToken)
            }

            if effectiveViewSelection == ConnectionViewTab.files.id {
                fileBrowserContent
            }

            if effectiveViewSelection == ConnectionViewTab.terminal.id && !shouldShowTerminal && !terminalAlreadyExists {
                ProgressView()
                    .progressViewStyle(.circular)
                    .scaleEffect(1.2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .id(session.id)
        .onAppear {
            prepareTerminal(viewSelection: effectiveViewSelection, terminalAlreadyExists: terminalAlreadyExists)
            if effectiveViewSelection == ConnectionViewTab.terminal.id {
                onFocusTerminal(session)
            }
        }
        .onChange(of: session.id) { _ in
            onActivateTerminal(session)
        }
        .onChange(of: viewSelection) { newValue in
            let effectiveSelection = viewTabConfig.effectiveView(for: newValue)
            if effectiveSelection == ConnectionViewTab.terminal.id {
                prepareTerminal(viewSelection: effectiveSelection, terminalAlreadyExists: terminalAlreadyExists)
                onFocusTerminal(session)
            }
            if effectiveSelection == ConnectionViewTab.files.id {
                onEnsureInitialFileTab()
            }
        }
    }

    @ViewBuilder
    private var fileBrowserContent: some View {
        if let server, let selectedFileTab {
            RemoteFileBrowserScreen(
                browser: fileBrowser,
                server: server,
                fileTab: selectedFileTab,
                initialPath: selectedFileTab.seedPath
            ) { currentPath in
                fileTabs.updateLastKnownPath(currentPath, for: selectedFileTab.id)
            }
            .id(selectedFileTab.id)
        }
    }

    private func prepareTerminal(viewSelection: String, terminalAlreadyExists: Bool) {
        switch IOSTerminalViewPolicy.terminalPreparation(
            sessionId: session.id,
            selectedViewId: viewSelection,
            terminalAlreadyExists: terminalAlreadyExists,
            isTerminalAlreadyScheduled: shouldShowTerminalBySession[session.id] == true
        ) {
        case .none:
            return
        case .refreshExisting:
            onRefreshTerminal(session)
        case .markVisible:
            shouldShowTerminalBySession[session.id] = true
        }
    }

    private func updateVoiceRecording(_ isRecording: Bool) {
        if isRecording {
            pendingVoiceReturnBySession[session.id] = false
        }
        voiceRecordingBySession[session.id] = isRecording
    }

    private func markPendingReturnIfNeeded() {
        if sessionManager.terminalBrowseModeBySession[session.id] == true {
            pendingVoiceReturnBySession[session.id] = true
        }
    }
}

#endif
