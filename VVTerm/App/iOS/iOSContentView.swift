//
//  iOSContentView.swift
//  VVTerm
//

import SwiftUI
import StoreKit
#if os(iOS)
import UIKit
#endif

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

struct iOSServerListView: View {
    @ObservedObject var serverManager: ServerManager
    @ObservedObject var sessionManager: ConnectionSessionManager
    let fileBrowser: RemoteFileBrowserStore
    @Binding var selectedWorkspace: Workspace?
    @Binding var selectedEnvironment: ServerEnvironment?
    @Binding var showingTerminal: Bool
    let onServerSelected: (Server) -> Void

    @ObservedObject private var storeManager = StoreManager.shared
    @ObservedObject private var viewTabConfig = ViewTabConfigurationManager.shared
    @State private var showingAddServer = false
    @State private var showingLocalDiscovery = false
    @State private var showingAddWorkspace = false
    @State private var showingSettings = false
    @State private var showingWorkspacePicker = false
    @State private var showingCreateEnvironment = false
    @State private var editingEnvironment: ServerEnvironment?
    @State private var environmentToDelete: ServerEnvironment?
    @State private var searchText = ""
    @State private var serverToEdit: Server?
    @State private var serverToMove: Server?
    @State private var lockedServerAlert: Server?
    @State private var navigationBarAppearanceToken = UUID()
    @State private var showingCustomEnvironmentAlert = false
    @State private var addServerPrefill: ServerFormPrefill?
    @State private var queuedDiscoveryPrefill: ServerFormPrefill?
    @AppStorage("appearanceMode") private var appearanceMode = AppearanceMode.system.rawValue

    private var canAddServer: Bool {
        !serverManager.workspaces.isEmpty
    }

    private var preferredConnectViewId: String {
        IOSConnectionViewSelectionPolicy.preferredConnectViewId(
            isTerminalVisible: viewTabConfig.isTabVisible(ConnectionViewTab.terminal.id),
            effectiveDefaultViewId: viewTabConfig.effectiveDefaultTab()
        )
    }

    var body: some View {
        List {
            serversSection
            activeConnectionsSection
        }
        .id(listRefreshIdentity)
        .overlay(alignment: .center) {
            if filteredServers.isEmpty {
                NoServersEmptyState(
                    onAddServer: { presentAddServer() },
                    onAddWorkspace: { showingAddWorkspace = true },
                    onDiscoverLocalDevices: { showingLocalDiscovery = true },
                    requiresWorkspace: serverManager.workspaces.isEmpty
                )
            }
        }
        .searchable(text: $searchText, prompt: "Search servers")
        .navigationTitle("Servers")
        .navigationBarTitleDisplayMode(.inline)
        .id(navigationBarAppearanceToken)
        .toolbar {
            ToolbarItem(placement: .principal) {
                workspaceToolbarButton
            }

            ToolbarItem(placement: .primaryAction) {
                Button {
                    presentAddServer()
                } label: {
                    Image(systemName: "plus")
                }
            }

            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    showingSettings = true
                } label: {
                    Image(systemName: "gear")
                }
            }
        }
        .onAppear {
            navigationBarAppearanceToken = UUID()
        }
        .sheet(isPresented: $showingAddServer) {
            NavigationStack {
                ServerFormSheet(
                    serverManager: serverManager,
                    workspace: selectedWorkspace,
                    prefill: addServerPrefill,
                    onSave: { _ in showingAddServer = false }
                )
            }
        }
        .sheet(isPresented: $showingLocalDiscovery) {
            LocalDeviceDiscoverySheet(manager: LocalSSHDiscoveryManager()) { discoveredHost in
                queuedDiscoveryPrefill = ServerFormPrefill(discoveredHost: discoveredHost)
                showingLocalDiscovery = false
            }
        }
        .sheet(isPresented: $showingAddWorkspace) {
            NavigationStack {
                WorkspaceFormSheet(
                    serverManager: serverManager,
                    onSave: { workspace in
                        selectedWorkspace = workspace
                        showingAddWorkspace = false
                    }
                )
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
                .modifier(AppearanceModifier())
        }
        .sheet(isPresented: $showingWorkspacePicker) {
            NavigationStack {
                iOSWorkspacePickerView(
                    serverManager: serverManager,
                    selectedWorkspace: $selectedWorkspace,
                    onDismiss: { showingWorkspacePicker = false }
                )
            }
        }
        .sheet(item: $serverToEdit) { server in
            NavigationStack {
                ServerFormSheet(
                    serverManager: serverManager,
                    workspace: selectedWorkspace,
                    server: server,
                    onSave: { updatedServer in
                        handleSavedServer(updatedServer, originalServer: server)
                        serverToEdit = nil
                    }
                )
            }
        }
        .sheet(item: $serverToMove) { server in
            NavigationStack {
                MoveServerSheet(
                    serverManager: serverManager,
                    server: server,
                    onMove: { updatedServer in
                        handleSavedServer(updatedServer, originalServer: server)
                        serverToMove = nil
                    }
                )
            }
        }
        .sheet(isPresented: $showingCreateEnvironment) {
            if let workspace = selectedWorkspace {
                EnvironmentFormSheet(
                    serverManager: serverManager,
                    workspace: workspace,
                    onSave: { updatedWorkspace, newEnvironment in
                        selectedWorkspace = updatedWorkspace
                        selectedEnvironment = newEnvironment
                        showingCreateEnvironment = false
                    }
                )
            }
        }
        .sheet(item: $editingEnvironment) { environment in
            if let workspace = selectedWorkspace {
                EnvironmentFormSheet(
                    serverManager: serverManager,
                    workspace: workspace,
                    environment: environment,
                    onSave: { updatedWorkspace, updatedEnvironment in
                        selectedWorkspace = updatedWorkspace
                        if selectedEnvironment?.id == updatedEnvironment.id {
                            selectedEnvironment = updatedEnvironment
                        }
                        editingEnvironment = nil
                    }
                )
            }
        }
        .alert(String(localized: "Delete Environment?"), isPresented: Binding(
            get: { environmentToDelete != nil },
            set: { if !$0 { environmentToDelete = nil } }
        )) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                guard let environment = environmentToDelete,
                      let workspace = selectedWorkspace else {
                    environmentToDelete = nil
                    return
                }
                serverManager.requestEnvironmentDeletion(
                    environment,
                    in: workspace,
                    fallback: .production
                ) { updatedWorkspace in
                    selectedWorkspace = updatedWorkspace
                    if selectedEnvironment?.id == environment.id {
                        selectedEnvironment = .production
                    }
                }
                environmentToDelete = nil
            }
        } message: {
            let name = environmentToDelete?.displayName ?? String(localized: "Custom")
            Text(String(format: String(localized: "Servers in '%@' will be moved to Production."), name))
        }
        .lockedItemAlert(
            .server,
            itemName: lockedServerAlert?.name ?? "",
            isPresented: Binding(
                get: { lockedServerAlert != nil },
                set: { if !$0 { lockedServerAlert = nil } }
            )
        )
        .proFeatureAlert(
            title: String(localized: "Custom Environments"),
            message: String(localized: "Upgrade to Pro for custom environments"),
            source: .customEnvironment,
            isPresented: $showingCustomEnvironmentAlert
        )
        .onChange(of: showingLocalDiscovery) { isPresented in
            guard !isPresented, let queued = queuedDiscoveryPrefill else { return }
            queuedDiscoveryPrefill = nil
            presentAddServer(prefill: queued)
        }
        .onChange(of: showingAddWorkspace) { isPresented in
            guard !isPresented else { return }
            resumePendingPrefilledAddServerIfNeeded()
        }
        .onChange(of: showingAddServer) { isPresented in
            if !isPresented {
                addServerPrefill = nil
            }
        }
    }

    private func handleSavedServer(_ server: Server, originalServer: Server) {
        let action = IOSServerListPolicy.savedServerSelectionAction(
            originalWorkspaceId: originalServer.workspaceId,
            savedWorkspaceId: server.workspaceId,
            selectedEnvironmentId: selectedEnvironment?.id,
            savedEnvironmentId: server.environment.id,
            destinationWorkspaceExists: serverManager.workspace(withId: server.workspaceId) != nil
        )

        if let destinationWorkspaceId = action.destinationWorkspaceId,
           let destinationWorkspace = serverManager.workspace(withId: destinationWorkspaceId) {
            selectedWorkspace = destinationWorkspace
        }

        if action.shouldClearSelectedEnvironment {
            selectedEnvironment = nil
        }
    }

    private var environmentOptions: [ServerEnvironment] {
        selectedWorkspace?.environments ?? ServerEnvironment.builtInEnvironments
    }

    private var selectedWorkspaceName: String {
        selectedWorkspace?.name ?? String(localized: "Select Workspace")
    }

    private var selectedWorkspaceColorHex: String {
        selectedWorkspace?.colorHex ?? "#007AFF"
    }

    private var filteredServerCountText: String {
        let serverCount = filteredServers.count
        if serverCount == 1 {
            return String(format: String(localized: "%lld server"), Int64(serverCount))
        }
        return String(format: String(localized: "%lld servers"), Int64(serverCount))
    }

    private var workspaceToolbarButton: some View {
        Button {
            showingWorkspacePicker = true
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color.fromHex(selectedWorkspaceColorHex))
                    .frame(width: 8, height: 8)

                Text(selectedWorkspaceName)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 220)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(selectedWorkspaceName)
        .accessibilityValue(filteredServerCountText)
        .accessibilityHint(String(localized: "Opens the workspace picker"))
    }

    @ViewBuilder
    private var serversSection: some View {
        Section {
            if filteredServers.isEmpty {
                Color.clear
                    .frame(height: 1)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            } else {
                ForEach(filteredServers) { server in
                    iOSServerRow(
                        server: server,
                        onTap: { onServerSelected(server) },
                        onEdit: { serverToEdit = server },
                        onMove: { serverToMove = server },
                        onLockedTap: { lockedServerAlert = server }
                    )
                }
            }
        } header: {
            HStack {
                Text("Servers")

                Spacer()

                if selectedWorkspace != nil {
                    iOSEnvironmentFilterMenu(
                        selected: $selectedEnvironment,
                        environments: environmentOptions,
                        serverCounts: serverCountsByEnvironment,
                        onCreateCustom: {
                            if storeManager.isPro {
                                showingCreateEnvironment = true
                            } else {
                                showingCustomEnvironmentAlert = true
                            }
                        },
                        onEditCustom: { environment in
                            if storeManager.isPro {
                                editingEnvironment = environment
                            } else {
                                showingCustomEnvironmentAlert = true
                            }
                        },
                        onDeleteCustom: { environment in
                            if storeManager.isPro {
                                environmentToDelete = environment
                            } else {
                                showingCustomEnvironmentAlert = true
                            }
                        }
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var activeConnectionsSection: some View {
        if !activeConnections.isEmpty && !filteredServers.isEmpty {
            Section {
                ForEach(activeConnections) { connection in
                    iOSActiveConnectionRow(
                        session: connection.session,
                        title: sessionManager.displayTitle(for: connection.session),
                        tabCount: connection.tabCount,
                        onOpen: { openActiveConnection(connection) },
                        onDisconnect: { disconnectActiveConnection(connection) }
                    )
                }
            } header: {
                Text("Active Connections")
            }
        }
    }

    private struct ActiveConnection: Identifiable {
        let id: UUID
        let session: ConnectionSession
        let tabCount: Int
    }

    private var activeConnections: [ActiveConnection] {
        let sessionsById = Dictionary(uniqueKeysWithValues: sessionManager.sessions.map { ($0.id, $0) })
        let snapshots = sessionManager.sessions.map {
            IOSActiveConnectionSessionSnapshot(
                id: $0.id,
                serverId: $0.serverId,
                displayTitle: sessionManager.displayTitle(for: $0)
            )
        }

        return IOSServerListPolicy.activeConnections(
            from: snapshots,
            selectedSessionId: sessionManager.selectedSessionId
        ).compactMap { snapshot in
            guard let session = sessionsById[snapshot.representativeSessionId] else { return nil }
            return ActiveConnection(id: snapshot.serverId, session: session, tabCount: snapshot.tabCount)
        }
    }

    private var filteredServers: [Server] {
        let serversById = Dictionary(uniqueKeysWithValues: serverManager.servers.map { ($0.id, $0) })
        return IOSServerListPolicy.filteredServers(
            serverManager.servers.map(\.iosServerListSnapshot),
            selectedWorkspaceId: selectedWorkspace?.id,
            selectedEnvironmentId: selectedEnvironment?.id,
            searchText: searchText
        ).compactMap { serversById[$0.id] }
    }

    private var listRefreshIdentity: String {
        IOSServerListPolicy.listRefreshIdentity(
            selectedWorkspaceId: selectedWorkspace?.id,
            selectedEnvironmentId: selectedEnvironment?.id,
            filteredServerIds: filteredServers.map(\.id),
            activeConnectionIds: activeConnections.map(\.id)
        )
    }

    private var serverCountsByEnvironment: [UUID: Int] {
        IOSServerListPolicy.serverCountsByEnvironment(
            servers: serverManager.servers.map(\.iosServerListSnapshot),
            workspaceId: selectedWorkspace?.id,
            environmentIds: selectedWorkspace?.environments.map(\.id) ?? []
        )
    }

    private func presentAddServer(prefill: ServerFormPrefill? = nil) {
        addServerPrefill = prefill
        guard canAddServer else {
            showingAddWorkspace = true
            return
        }
        showingAddServer = true
    }

    private func resumePendingPrefilledAddServerIfNeeded() {
        guard addServerPrefill != nil, canAddServer, !showingAddServer else { return }
        showingAddServer = true
    }

    private func openActiveConnection(_ connection: ActiveConnection) {
        let targetViewId = preferredConnectViewId
        guard let server = server(for: connection.id) else { return }

        AppLockManager.shared.requestServerUnlock(server, onUnlocked: {
            sessionManager.requestActiveConnectionOpen(
                session: connection.session,
                preferredViewId: targetViewId
            ) {
                showingTerminal = true
            }
        })
    }

    private func disconnectActiveConnection(_ connection: ActiveConnection) {
        ServerConnectionLifecycleCoordinator.shared.requestServerDisconnect(
            serverId: connection.id,
            disconnectRemoteFiles: { serverId in
                fileBrowser.disconnect(serverId: serverId)
            },
            disconnectTerminals: sessionManager.disconnectServerAndWait
        )
    }

    private func server(for serverId: UUID) -> Server? {
        serverManager.servers.first { $0.id == serverId }
    }
}

private extension Server {
    var iosServerListSnapshot: IOSServerListServerSnapshot {
        IOSServerListServerSnapshot(
            id: id,
            workspaceId: workspaceId,
            environmentId: environment.id,
            name: name,
            host: host
        )
    }
}

// MARK: - iOS Terminal View

struct iOSTerminalView: View {
    @ObservedObject var sessionManager: ConnectionSessionManager
    @ObservedObject var serverManager: ServerManager
    @ObservedObject var fileTabs: RemoteFileTabManager
    let fileBrowser: RemoteFileBrowserStore
    let connectingServer: Server?
    let isConnecting: Bool
    let onBack: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var viewTabConfig = ViewTabConfigurationManager.shared

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

    @AppStorage(CloudKitSyncConstants.terminalThemeNameKey) private var terminalThemeName = "Aizen Dark"
    @AppStorage(CloudKitSyncConstants.terminalThemeNameLightKey) private var terminalThemeNameLight = "Aizen Light"
    @AppStorage(CloudKitSyncConstants.terminalUsePerAppearanceThemeKey) private var usePerAppearanceTheme = true
    @AppStorage("sshAutoReconnect") private var autoReconnectEnabled = true
    @AppStorage("terminalVoiceButtonEnabled") private var terminalVoiceButtonEnabled = true
    private var effectiveThemeName: String {
        guard usePerAppearanceTheme else { return terminalThemeName }
        return colorScheme == .dark ? terminalThemeName : terminalThemeNameLight
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
        currentServerId ?? selectedServer?.id ?? connectingServer?.id
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

    private var isCloseAlertPresented: Binding<Bool> {
        Binding(
            get: { pendingCloseSession != nil },
            set: { newValue in
                if !newValue {
                    pendingCloseSession = nil
                }
            }
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
            isVoiceButtonEnabled: terminalVoiceButtonEnabled,
            hasPendingVoiceReturn: effectiveSelectedSessionId.map {
                pendingVoiceReturnBySession[$0] == true
            } ?? false
        )
    }

    private var shouldShowFloatingTerminalControls: Bool {
        floatingControlsVisibility.shouldShowControls
    }

    private var shouldShowFloatingVoiceButton: Bool {
        floatingControlsVisibility.shouldShowVoiceButton
    }

    private var shouldShowFloatingReturnButton: Bool {
        floatingControlsVisibility.shouldShowReturnButton
    }

    private var canUseZenMode: Bool {
        isConnecting || selectedServer != nil || !serverSessions.isEmpty
    }

    private var effectiveZenModeEnabled: Bool {
        isZenModeEnabled && canUseZenMode
    }

    private var shouldShowViewSwitcher: Bool {
        viewTabConfig.currentVisibleTabs.count > 1
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
        IOSFileTabTitlePolicy.baseTitle(
            for: fileTabTitleInput(for: tab),
            serverName: selectedServer?.name.nonEmptyString
        )
    }

    private func displayedFileTabTitle(for tab: RemoteFileTab) -> String {
        let resolvedTitles = IOSFileTabTitlePolicy.displayedTitles(
            for: serverFileTabs.map { fileTabTitleInput(for: $0) },
            serverName: selectedServer?.name.nonEmptyString
        )
        return resolvedTitles[tab.id] ?? baseFileTabTitle(for: tab)
    }

    private func fileTabTitleInput(for tab: RemoteFileTab) -> IOSFileTabTitleInput {
        IOSFileTabTitleInput(
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
        UserDefaults.standard.set(
            resolved.storageHex,
            forKey: TerminalThemeBackgroundResolver.cacheKey
        )
    }

    private func attemptForegroundReconnectIfNeeded(refreshTerminal: Bool = false) {
        sessionManager.requestForegroundReconnectForSelectedSession(
            selectedViewId: selectedView,
            terminalViewId: ConnectionViewTab.terminal.id,
            refreshTerminal: refreshTerminal,
            autoReconnectEnabled: autoReconnectEnabled
        ) { action in
            guard let session = sessionManager.sessions.first(where: { $0.id == action.sessionId }) else { return }

            if action.shouldRefreshTerminal {
                activateTerminal(session)
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
        alertContent
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
            .onChange(of: terminalThemeName) { _ in updateTerminalBackgroundColor() }
            .onChange(of: terminalThemeNameLight) { _ in updateTerminalBackgroundColor() }
            .onChange(of: usePerAppearanceTheme) { _ in updateTerminalBackgroundColor() }
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
        mainContent
            .background(backgroundView)
            .overlay(alignment: .top) {
                if selectedView == "terminal" && !effectiveZenModeEnabled {
                    NavBarBackdrop(color: terminalBackgroundColor)
                }
            }
            .overlay(alignment: .topTrailing) {
                if effectiveZenModeEnabled {
                    zenModeOverlay
                }
            }
            .overlay(alignment: .bottom) {
                if shouldShowFloatingTerminalControls {
                    floatingTerminalControls
                        .padding(.bottom, 4)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .navigationBarBackButtonHidden(true)
            .toolbar { navigationToolbar }
            .toolbar(effectiveZenModeEnabled ? .hidden : .visible, for: .navigationBar)
            .animation(.spring(response: 0.28, dampingFraction: 0.84), value: shouldShowFloatingTerminalControls)
            .animation(.spring(response: 0.28, dampingFraction: 0.84), value: shouldShowFloatingReturnButton)
    }

    private var sheetContent: some View {
        baseContent
            .limitReachedAlert(.tabs, isPresented: $showingTabLimitAlert)
            .limitReachedAlert(.fileTabs, isPresented: $showingFileTabLimitAlert)
            .sheet(isPresented: $showingSettings) {
                SettingsView()
                    .modifier(AppearanceModifier())
            }
            .sheet(item: $serverToEdit) { server in
                NavigationStack {
                    ServerFormSheet(
                        serverManager: serverManager,
                        workspace: serverManager.workspaces.first { $0.id == server.workspaceId },
                        server: server,
                        onSave: { _ in serverToEdit = nil }
                    )
                }
            }
            .sheet(item: tmuxAttachPromptBinding) { prompt in
                TmuxAttachPromptSheet(
                    prompt: prompt,
                    onConfirm: { selection in
                        sessionManager.resolveTmuxAttachPrompt(sessionId: prompt.id, selection: selection)
                    }
                )
            }
    }

    private var alertContent: some View {
        sheetContent
            .alert(String(localized: "Close Tab?"), isPresented: isCloseAlertPresented, presenting: pendingCloseSession) { session in
                Button("Close", role: .destructive) {
                    sessionManager.closeSession(session)
                    pendingCloseSession = nil
                }
                Button("Cancel", role: .cancel) {
                    pendingCloseSession = nil
                }
            } message: { session in
                Text(String(format: String(localized: "This will disconnect \"%@\"."), session.title))
            }
    }

    @ViewBuilder
    private var mainContent: some View {
        VStack(spacing: 0) {
            headerTabsBar
            sessionContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var headerTabsBar: some View {
        if !effectiveZenModeEnabled {
            if selectedView == "terminal" && serverSessions.count > 1 {
                iOSTerminalTabsBar(
                    sessions: serverSessions,
                    selectedSessionId: selectedSessionIdBinding,
                    titleForSession: { sessionManager.displayTitle(for: $0) },
                    onClose: { pendingCloseSession = $0 }
                )
            }

            if selectedView == "files" && serverFileTabs.count > 1 {
                iOSRemoteFileTabsBar(
                    tabs: serverFileTabs,
                    selectedTabId: selectedFileTabIdBinding,
                    titleForTab: displayedFileTabTitle(for:),
                    onSelect: { fileTabs.selectTab($0) },
                    onClose: closeFileTab
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
            connectingStateView(serverName: serverName)
        } else if selectedView == "terminal" {
            TerminalEmptyStateView(server: selectedServer) {
                openNewTab()
            }
        } else if selectedView == "files", let server = selectedServer {
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
                    openNewFileTab()
                }
            }
        } else if let server = selectedServer {
            ServerStatsView(
                server: server,
                isVisible: true,
                backgroundColor: Color(UIColor.systemGroupedBackground),
                borrowedLeaseProvider: { sessionManager.sharedStatsLease(for: server.id) },
                statsCollector: ServerStatsCollector(connectionProvider: StatsSSHConnectionProvider.makeProvider())
            )
        }
    }

    private var activeSessionsContent: some View {
        ZStack {
            if selectedView == "stats", let server = selectedServer {
                ServerStatsView(
                    server: server,
                    isVisible: true,
                    backgroundColor: Color(UIColor.systemGroupedBackground),
                    borrowedLeaseProvider: { sessionManager.sharedStatsLease(for: server.id) },
                    statsCollector: ServerStatsCollector(connectionProvider: StatsSSHConnectionProvider.makeProvider())
                )
                .zIndex(1)
            }

            if selectedView == "files" {
                if let server = selectedServer {
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
                        .zIndex(1)
                    } else {
                        RemoteFileTabsEmptyState {
                            openNewFileTab()
                        }
                        .zIndex(1)
                    }
                }
            }

            if selectedView == "terminal", let session = selectedSession ?? serverSessions.first {
                sessionPage(session)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transaction { transaction in
            transaction.animation = nil
        }
        .overlay(serverViewSwipeOverlay)
    }

    @ViewBuilder
    private var backgroundView: some View {
        if selectedView == "terminal" {
            terminalBackgroundColor
                .ignoresSafeArea(.all)
        } else {
            Color(UIColor.systemBackground)
                .ignoresSafeArea(.all)
        }
    }

    @ToolbarContentBuilder
    private var navigationToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            navigationBackButton
        }

        if shouldShowViewSwitcher {
            ToolbarItem(placement: .principal) {
                if let serverId = resolvedServerId {
                    iOSNativeSegmentedPicker(
                        selection: selectedViewBinding(for: serverId),
                        tabs: viewTabConfig.currentVisibleTabs
                    )
                    .fixedSize()
                }
            }
        }

        ToolbarItemGroup(placement: .navigationBarTrailing) {
            if selectedView == "terminal" {
                Button {
                    openNewTab()
                } label: {
                    Image(systemName: "plus")
                }
            }

            if selectedView == "files" {
                Button {
                    openNewFileTab()
                } label: {
                    Image(systemName: "plus")
                }
            }

            Menu {
                Button {
                    showingSettings = true
                } label: {
                    Label("Settings", systemImage: "gear")
                }

                if selectedView == "terminal" {
                    Button {
                        showFindNavigatorForCurrentSession()
                    } label: {
                        Label("Find", systemImage: "magnifyingglass")
                    }
                }

                if let server = selectedServer {
                    Button {
                        serverToEdit = server
                    } label: {
                        Label("Edit Server", systemImage: "pencil")
                    }
                }

                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                        isZenModeEnabled = true
                    }
                } label: {
                    Label("Zen Mode", systemImage: "arrow.up.left.and.arrow.down.right")
                }

                Button(role: .destructive) {
                    disconnectCurrentServerSessions()
                } label: {
                    Label("Disconnect", systemImage: "xmark.circle")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    private var navigationBackButton: some View {
        Button {
            dismissKeyboardForCurrentSession()
            onBack()
        } label: {
            Image(systemName: "chevron.left")
        }
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
              terminalVoiceButtonEnabled,
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
        if shouldShowFloatingReturnButton {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    floatingKeyboardVoiceControls(showsTitle: true)
                    Spacer(minLength: 14)
                    floatingReturnControl()
                }

                HStack(spacing: 10) {
                    floatingKeyboardVoiceControls(showsTitle: false)
                    Spacer(minLength: 14)
                    floatingReturnControl()
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    floatingKeyboardVoiceControls(showsTitle: true)
                }

                HStack(spacing: 10) {
                    floatingKeyboardVoiceControls(showsTitle: false)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    @ViewBuilder
    private func floatingKeyboardVoiceControls(showsTitle: Bool) -> some View {
        HStack(spacing: 10) {
            floatingKeyboardControl(showsTitle: showsTitle)
            if shouldShowFloatingVoiceButton {
                floatingVoiceControl(showsTitle: showsTitle)
            }
        }
    }

    @ViewBuilder
    private func floatingKeyboardControl(showsTitle: Bool) -> some View {
        floatingTerminalControlButton(
            title: "Keyboard",
            systemImage: "keyboard",
            accessibilityLabel: "Show Keyboard",
            showsTitle: showsTitle
        ) {
            showKeyboardForCurrentSession()
        }
    }

    @ViewBuilder
    private func floatingVoiceControl(showsTitle: Bool) -> some View {
        floatingTerminalControlButton(
            title: "Voice input",
            systemImage: "mic.fill",
            accessibilityLabel: "Voice input",
            showsTitle: showsTitle
        ) {
            startVoiceInputForCurrentSession()
        }
    }

    @ViewBuilder
    private func floatingReturnControl() -> some View {
        floatingTerminalControlButton(
            title: "Enter",
            systemImage: "arrow.turn.down.left",
            accessibilityLabel: "Enter",
            showsTitle: false,
            isPrimary: true
        ) {
            sendReturnForCurrentSession()
        }
    }

    @ViewBuilder
    private func floatingTerminalControlButton(
        title: LocalizedStringKey,
        systemImage: String,
        accessibilityLabel: LocalizedStringKey,
        showsTitle: Bool,
        isPrimary: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        let button = Button(action: action) {
            HStack(spacing: showsTitle ? 6 : 0) {
                Image(systemName: systemImage)
                if showsTitle {
                    Text(title)
                }
            }
            .font(.system(size: 15, weight: .semibold, design: .rounded))
            .foregroundStyle(isPrimary ? Color.accentColor : Color.primary)
            .padding(.horizontal, showsTitle ? 2 : 0)
        }
        .accessibilityLabel(Text(accessibilityLabel))

        button
            .buttonStyle(.glass(tint: Color.accentColor.opacity(isPrimary ? 0.5 : (colorScheme == .dark ? 0.24 : 0.14))))
            .buttonBorderShape(.capsule)
            .controlSize(.large)
    }

    @ViewBuilder
    private func connectingStateView(serverName: String) -> some View {
        BlockingStatusView(showsScrim: false) {
            VStack(spacing: 12) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .scaleEffect(1.1)
                Text(String(format: String(localized: "Connecting to %@..."), serverName))
                    .font(.headline)
                Text(String(localized: "Preparing server details..."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func sessionPage(_ session: ConnectionSession) -> some View {
        let server = serverManager.servers.first { $0.id == session.serverId }
        let viewSelection = sessionManager.selectedViewByServer[session.serverId] ?? viewTabConfig.effectiveDefaultTab()
        let effectiveViewSelection = viewTabConfig.effectiveView(for: viewSelection)
        let terminalAlreadyExists = sessionManager.hasTerminal(for: session.id)
        let shouldShowTerminal = shouldShowTerminalBySession[session.id] ?? false
        let reconnectToken = reconnectTokenBySession[session.id] ?? session.id

        ZStack {
            if shouldShowTerminal || terminalAlreadyExists {
                TerminalContainerView(
                    session: session,
                    server: server,
                    sessionManager: sessionManager,
                    isActive: effectiveViewSelection == "terminal",
                    onVoiceRecordingChange: { isRecording in
                        if isRecording {
                            clearPendingVoiceReturn(for: session.id)
                        }
                        voiceRecordingBySession[session.id] = isRecording
                    },
                    onVoiceTranscriptionSent: {
                        if sessionManager.terminalBrowseModeBySession[session.id] == true {
                            pendingVoiceReturnBySession[session.id] = true
                        }
                    }
                )
                .id(reconnectToken)
            }

            if effectiveViewSelection == "files" {
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

            if effectiveViewSelection == "terminal" && !shouldShowTerminal && !terminalAlreadyExists {
                ProgressView()
                    .progressViewStyle(.circular)
                    .scaleEffect(1.2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .id(session.id)
        .onAppear {
            prepareTerminal(session: session, viewSelection: effectiveViewSelection, terminalAlreadyExists: terminalAlreadyExists)
            if effectiveViewSelection == "terminal" {
                focusTerminal(for: session)
            }
        }
        .onChange(of: session.id) { _ in
            activateTerminal(session)
        }
        .onChange(of: viewSelection) { newValue in
            let effectiveSelection = viewTabConfig.effectiveView(for: newValue)
            if effectiveSelection == "terminal" {
                prepareTerminal(session: session, viewSelection: effectiveSelection, terminalAlreadyExists: terminalAlreadyExists)
                focusTerminal(for: session)
            }
            if effectiveSelection == ConnectionViewTab.files.id {
                ensureInitialFileTabIfNeeded()
            }
        }
    }

    private func prepareTerminal(session: ConnectionSession, viewSelection: String, terminalAlreadyExists: Bool) {
        switch IOSTerminalViewPolicy.terminalPreparation(
            sessionId: session.id,
            selectedViewId: viewSelection,
            terminalAlreadyExists: terminalAlreadyExists,
            isTerminalAlreadyScheduled: shouldShowTerminalBySession[session.id] == true
        ) {
        case .none:
            return
        case .refreshExisting:
            refreshTerminal(for: session)
        case .markVisible:
            shouldShowTerminalBySession[session.id] = true
        }
    }

    private func activateTerminal(_ session: ConnectionSession) {
        let terminalAlreadyExists = sessionManager.hasTerminal(for: session.id)
        prepareTerminal(session: session, viewSelection: selectedView, terminalAlreadyExists: terminalAlreadyExists)
        guard selectedView == "terminal" else { return }
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
        ServerConnectionLifecycleCoordinator.shared.requestServerDisconnect(
            serverId: serverId,
            disconnectRemoteFiles: { serverId in
                fileBrowser.disconnect(serverId: serverId)
            },
            disconnectFileTabs: { serverId in
                fileTabs.disconnect(serverId: serverId)
            },
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

    private var zenModeOverlay: some View {
        ZenModeFloatingOverlay(
            isPanelPresented: $showingZenPanel,
            indicatorColor: selectedSession?.connectionState.statusTintColor ?? .secondary
        ) { panelWidth in
            IOSZenModePanel(
                width: panelWidth,
                serverName: selectedServer?.name ?? String(localized: "Terminal"),
                selectedView: selectedView,
                selectedViewBinding: zenSelectedViewBinding,
                viewTabs: viewTabConfig.currentVisibleTabs,
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
                onCloseFileTab: { tab in
                    closeFileTab(tab)
                },
                onNewTerminalTab: {
                    showingZenPanel = false
                    openNewTab()
                },
                onNewFileTab: {
                    showingZenPanel = false
                    openNewFileTab()
                },
                onOpenSettings: {
                    showingZenPanel = false
                    showingSettings = true
                },
                onEditServer: selectedServer.map { server in
                    {
                        showingZenPanel = false
                        serverToEdit = server
                    }
                },
                onDisconnect: {
                    showingZenPanel = false
                    disconnectCurrentServerSessions()
                },
                onBack: {
                    showingZenPanel = false
                    dismissKeyboardForCurrentSession()
                    onBack()
                },
                onExitZen: {
                    showingZenPanel = false
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                        isZenModeEnabled = false
                    }
                }
            )
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


    @ViewBuilder
    private var serverViewSwipeOverlay: some View {
        if (selectedView == ConnectionViewTab.terminal.id && serverSessions.count > 1)
            || (selectedView == ConnectionViewTab.files.id && serverFileTabs.count > 1) {
            GeometryReader { _ in
                let edgeWidth: CGFloat = 32
                let leadingGestureInset: CGFloat = selectedView == ConnectionViewTab.files.id ? 44 : 0
                HStack(spacing: 0) {
                    Color.clear
                        .frame(width: leadingGestureInset)
                        .allowsHitTesting(false)

                    Color.clear
                        .frame(width: edgeWidth)
                        .contentShape(Rectangle())
                        .gesture(tabSwipeGesture())

                    Color.clear
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .allowsHitTesting(false)

                    Color.clear
                        .frame(width: edgeWidth)
                        .contentShape(Rectangle())
                        .gesture(tabSwipeGesture())
                }
            }
        }
    }

    private func tabSwipeGesture() -> some Gesture {
        DragGesture(minimumDistance: 24, coordinateSpace: .local)
            .onEnded { value in
                let horizontal = value.translation.width
                let vertical = value.translation.height
                guard abs(horizontal) > abs(vertical),
                      abs(horizontal) > 60 else { return }
                if horizontal < 0 {
                    if selectedView == ConnectionViewTab.files.id {
                        selectNextFileTab()
                    } else {
                        selectNextServerSession()
                    }
                } else {
                    if selectedView == ConnectionViewTab.files.id {
                        selectPreviousFileTab()
                    } else {
                        selectPreviousServerSession()
                    }
                }
            }
    }

    private func selectNextServerSession() {
        guard let currentId = sessionManager.selectedSessionId,
              let index = serverSessions.firstIndex(where: { $0.id == currentId }),
              index < serverSessions.count - 1 else { return }
        sessionManager.selectedSessionId = serverSessions[index + 1].id
        triggerTabSwitchFeedback()
    }

    private func selectPreviousServerSession() {
        guard let currentId = sessionManager.selectedSessionId,
              let index = serverSessions.firstIndex(where: { $0.id == currentId }),
              index > 0 else { return }
        sessionManager.selectedSessionId = serverSessions[index - 1].id
        triggerTabSwitchFeedback()
    }

    private func selectNextFileTab() {
        guard let serverId = fileTabServerId else { return }
        fileTabs.selectNextTab(for: serverId)
        triggerTabSwitchFeedback()
    }

    private func selectPreviousFileTab() {
        guard let serverId = fileTabServerId else { return }
        fileTabs.selectPreviousTab(for: serverId)
        triggerTabSwitchFeedback()
    }

    private func triggerTabSwitchFeedback() {
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.prepare()
        generator.impactOccurred()
    }

}

private extension ConnectionSession {
    var iosTerminalSessionSnapshot: IOSTerminalSessionSnapshot {
        IOSTerminalSessionSnapshot(
            id: id,
            serverId: serverId
        )
    }
}

#endif
