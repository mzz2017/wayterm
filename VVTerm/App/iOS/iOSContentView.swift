//
//  iOSContentView.swift
//  VVTerm
//

import SwiftUI
import StoreKit

#if os(iOS)
struct iOSContentView: View {
    let fileTabs: RemoteFileTabManager
    let fileBrowser: RemoteFileBrowserStore
    @StateObject private var serverManager = ServerManager.shared
    @StateObject private var sessionManager = ConnectionSessionManager.shared
    @StateObject private var viewTabConfig = ViewTabConfigurationManager.shared
    @StateObject private var engagementTracker = EngagementTracker.shared
    @Environment(\.requestReview) private var requestReview

    @State private var selectedWorkspace: Workspace?
    @State private var selectedServer: Server?
    @State private var selectedEnvironment: ServerEnvironment?
    @State private var showingTerminal = false
    @State private var showingTabLimitAlert = false
    @State private var lockedServerName: String?
    @State private var connectingServer: Server?
    @State private var isConnecting = false

    private var rootNavigationState: IOSRootNavigationState {
        IOSRootNavigationState(
            isConnecting: isConnecting,
            connectingServerId: connectingServer?.id,
            sessionServerIds: sessionManager.sessions.map(\.serverId)
        )
    }

    private var preferredConnectViewId: String {
        IOSConnectionViewSelectionPolicy.preferredConnectViewId(
            isTerminalVisible: viewTabConfig.isTabVisible(ConnectionViewTab.terminal.id),
            effectiveDefaultViewId: viewTabConfig.effectiveDefaultTab()
        )
    }

    var body: some View {
        NavigationStack {
            iOSServerListView(
                serverManager: serverManager,
                sessionManager: sessionManager,
                fileBrowser: fileBrowser,
                selectedWorkspace: $selectedWorkspace,
                selectedEnvironment: $selectedEnvironment,
                showingTerminal: $showingTerminal,
                onServerSelected: { server in
                    selectedServer = server
                    connectingServer = server
                    isConnecting = true
                    showingTerminal = true
                    sessionManager.selectedViewByServer[server.id] = preferredConnectViewId

                    sessionManager.requestConnectionOpen(
                        to: server,
                        forceNew: IOSServerListPolicy.shouldForceNewConnectionFromServerList,
                        onOpened: { session in
                            sessionManager.selectedViewByServer[server.id] = preferredConnectViewId
                            sessionManager.selectedSessionId = session.id
                            isConnecting = false
                            connectingServer = nil
                        },
                        onFailed: { error in
                            isConnecting = false
                            connectingServer = nil
                            showingTerminal = false

                            if let error = error as? VVTermError {
                                switch error {
                                case .proRequired:
                                    showingTabLimitAlert = true
                                case .serverLocked(let name):
                                    lockedServerName = name
                                default:
                                    break
                                }
                            }
                        }
                    )
                }
            )
            .navigationDestination(isPresented: $showingTerminal) {
                iOSTerminalView(
                    sessionManager: sessionManager,
                    serverManager: serverManager,
                    fileTabs: fileTabs,
                    fileBrowser: fileBrowser,
                    connectingServer: connectingServer,
                    isConnecting: isConnecting,
                    onBack: { showingTerminal = false }
                )
            }
        }
        .navigationBarAppearance(backgroundColor: .clear, isTranslucent: true, shadowColor: .clear)
        .onAppear {
            // Select first workspace on appear
            if selectedWorkspace == nil {
                selectedWorkspace = serverManager.workspaces.first
            }
            if IOSRootNavigationPolicy.shouldDismissTerminal(
                isShowingTerminal: showingTerminal,
                state: rootNavigationState
            ) {
                showingTerminal = false
            }
        }
        .onChange(of: serverManager.workspaces) { workspaces in
            if selectedWorkspace == nil {
                selectedWorkspace = workspaces.first
            }
        }
        // Sync navigation state with session state - dismiss terminal if session is gone
        .onChangeCompat(of: sessionManager.sessions) { _ in
            if IOSRootNavigationPolicy.shouldDismissTerminal(
                isShowingTerminal: showingTerminal,
                state: rootNavigationState
            ) {
                showingTerminal = false
            }
            if IOSRootNavigationPolicy.shouldClearConnectingState(rootNavigationState) {
                isConnecting = false
                self.connectingServer = nil
            }
        }
        .onChange(of: sessionManager.selectedSessionId) { selectedId in
            if IOSRootNavigationPolicy.shouldDismissTerminalAfterSelectedSessionChange(
                isShowingTerminal: showingTerminal,
                selectedSessionId: selectedId,
                state: rootNavigationState
            ) {
                showingTerminal = false
            }
        }
        .limitReachedAlert(.tabs, isPresented: $showingTabLimitAlert)
        .proUpgradePresentation(isPresented: $engagementTracker.shouldShowProIntro, source: .postFirstConnection)
        .onChange(of: showingTerminal) { isShowing in
            if !isShowing {
                engagementTracker.noteTerminalSessionEnded(
                    otherTerminalsActive: false,
                    isPro: StoreManager.shared.isPro
                )
            }
        }
        .onChange(of: engagementTracker.reviewRequestToken) { _ in
            requestReview()
        }
        .lockedItemAlert(
            .server,
            itemName: lockedServerName ?? "",
            isPresented: Binding(
                get: { lockedServerName != nil },
                set: { if !$0 { lockedServerName = nil } }
            )
        )
    }
}

#endif
