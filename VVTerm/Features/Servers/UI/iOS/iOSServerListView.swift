import SwiftUI

#if os(iOS)
struct iOSServerListView: View {
    @ObservedObject var serverManager: ServerManager
    @ObservedObject var sessionManager: ConnectionSessionManager
    @ObservedObject var storeManager: StoreManager
    let fileBrowser: RemoteFileBrowserStore
    @Binding var selectedWorkspace: Workspace?
    @Binding var selectedEnvironment: ServerEnvironment?
    @Binding var showingTerminal: Bool
    let onServerSelected: (Server) -> Void
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
                    storeManager: storeManager,
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
                    storeManager: storeManager,
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
                    storeManager: storeManager,
                    selectedWorkspace: $selectedWorkspace,
                    onDismiss: { showingWorkspacePicker = false }
                )
            }
        }
        .sheet(item: $serverToEdit) { server in
            NavigationStack {
                ServerFormSheet(
                    serverManager: serverManager,
                    storeManager: storeManager,
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
                    storeManager: storeManager,
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
                        serverManager: serverManager,
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
#endif
