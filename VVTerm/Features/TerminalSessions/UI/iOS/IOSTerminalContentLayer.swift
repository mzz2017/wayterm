import SwiftUI
#if os(iOS)

struct IOSTerminalContentLayer: View {
    let effectiveZenModeEnabled: Bool
    let selectedView: String
    let isConnecting: Bool
    let connectingServer: Server?
    let selectedServer: Server?
    let serverSessions: [ConnectionSession]
    @Binding var selectedSessionId: UUID?
    let titleForSession: (ConnectionSession) -> String
    let onCloseSession: (ConnectionSession) -> Void
    let serverFileTabs: [RemoteFileTab]
    @Binding var selectedFileTabId: UUID?
    let fileTabTitle: (RemoteFileTab) -> String
    let onSelectFileTab: (RemoteFileTab) -> Void
    let onCloseFileTab: (RemoteFileTab) -> Void
    let selectedFileTab: RemoteFileTab?
    let fileTabServerId: UUID?
    let fileBrowser: RemoteFileBrowserStore
    @ObservedObject var fileTabs: RemoteFileTabManager
    let terminalBackgroundColor: Color
    let statsLeaseProvider: (UUID) -> RemoteConnectionLease?
    @ObservedObject var serverManager: ServerManager
    @ObservedObject var sessionManager: ConnectionSessionManager
    @ObservedObject var viewTabConfig: ViewTabConfigurationManager
    @Binding var shouldShowTerminalBySession: [UUID: Bool]
    @Binding var voiceRecordingBySession: [UUID: Bool]
    @Binding var pendingVoiceReturnBySession: [UUID: Bool]
    let reconnectTokenForSession: (ConnectionSession) -> UUID
    let onActivateTerminal: (ConnectionSession) -> Void
    let onRefreshTerminal: (ConnectionSession) -> Void
    let onFocusTerminal: (ConnectionSession) -> Void
    let onEnsureInitialFileTab: () -> Void
    let onNewTerminalTab: () -> Void
    let onNewFileTab: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            headerTabsBar
            sessionContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(backgroundView)
    }

    @ViewBuilder
    private var headerTabsBar: some View {
        if !effectiveZenModeEnabled {
            if selectedView == ConnectionViewTab.terminal.id && serverSessions.count > 1 {
                iOSTerminalTabsBar(
                    sessions: serverSessions,
                    selectedSessionId: $selectedSessionId,
                    titleForSession: titleForSession,
                    onClose: onCloseSession
                )
            }

            if selectedView == ConnectionViewTab.files.id && serverFileTabs.count > 1 {
                iOSRemoteFileTabsBar(
                    tabs: serverFileTabs,
                    selectedTabId: $selectedFileTabId,
                    titleForTab: fileTabTitle,
                    onSelect: onSelectFileTab,
                    onClose: onCloseFileTab
                )
            }
        }
    }

    @ViewBuilder
    private var sessionContent: some View {
        if serverSessions.isEmpty {
            emptyStateContent
        } else {
            activeSessionsContent
        }
    }

    @ViewBuilder
    private var emptyStateContent: some View {
        if isConnecting, let serverName = (connectingServer ?? selectedServer)?.name {
            IOSTerminalConnectingStateView(serverName: serverName)
        } else if selectedView == ConnectionViewTab.terminal.id {
            TerminalEmptyStateView(server: selectedServer) {
                onNewTerminalTab()
            }
        } else if selectedView == ConnectionViewTab.files.id, let server = selectedServer {
            fileBrowserContent(server: server)
        } else if let server = selectedServer {
            statsContent(server: server)
        }
    }

    private var activeSessionsContent: some View {
        ZStack {
            if selectedView == ConnectionViewTab.stats.id, let server = selectedServer {
                statsContent(server: server)
                    .zIndex(1)
            }

            if selectedView == ConnectionViewTab.files.id, let server = selectedServer {
                fileBrowserContent(server: server)
                    .zIndex(1)
            }

            if selectedView == ConnectionViewTab.terminal.id,
               let session = selectedSession {
                IOSTerminalSessionPage(
                    session: session,
                    serverManager: serverManager,
                    sessionManager: sessionManager,
                    viewTabConfig: viewTabConfig,
                    fileTabs: fileTabs,
                    fileBrowser: fileBrowser,
                    selectedFileTab: selectedFileTab,
                    shouldShowTerminalBySession: $shouldShowTerminalBySession,
                    voiceRecordingBySession: $voiceRecordingBySession,
                    pendingVoiceReturnBySession: $pendingVoiceReturnBySession,
                    reconnectToken: reconnectTokenForSession(session),
                    onActivateTerminal: onActivateTerminal,
                    onRefreshTerminal: onRefreshTerminal,
                    onFocusTerminal: onFocusTerminal,
                    onEnsureInitialFileTab: onEnsureInitialFileTab
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transaction { transaction in
            transaction.animation = nil
        }
        .overlay {
            IOSTerminalTabSwipeOverlay(
                selectedView: selectedView,
                serverSessions: serverSessions,
                fileTabServerId: fileTabServerId,
                selectedSessionId: $selectedSessionId,
                fileTabs: fileTabs
            )
        }
    }

    private var selectedSession: ConnectionSession? {
        if let selectedSessionId,
           let selected = serverSessions.first(where: { $0.id == selectedSessionId }) {
            return selected
        }
        return serverSessions.first
    }

    @ViewBuilder
    private func fileBrowserContent(server: Server) -> some View {
        if let selectedFileTab {
            RemoteFileBrowserScreen(
                browser: fileBrowser,
                server: server,
                fileTab: selectedFileTab,
                initialPath: selectedFileTab.seedPath
            ) { currentPath in
                fileTabs.updateLastKnownPath(currentPath, for: selectedFileTab.id)
            }
            .id(selectedFileTab.id)
        } else {
            RemoteFileTabsEmptyState {
                onNewFileTab()
            }
        }
    }

    private func statsContent(server: Server) -> some View {
        ServerStatsView(
            server: server,
            isVisible: true,
            backgroundColor: Color(UIColor.systemGroupedBackground),
            borrowedLeaseProvider: { statsLeaseProvider(server.id) },
            statsCollector: ServerStatsCollector(connectionProvider: StatsSSHConnectionProvider.makeProvider())
        )
    }

    @ViewBuilder
    private var backgroundView: some View {
        if selectedView == ConnectionViewTab.terminal.id {
            terminalBackgroundColor
                .ignoresSafeArea(.all)
        } else {
            Color(UIColor.systemBackground)
                .ignoresSafeArea(.all)
        }
    }
}

#endif
