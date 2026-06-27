//
//  ConnectionTabsView.swift
//  VVTerm
//

import SwiftUI
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

// MARK: - Connection Terminal Container

struct ConnectionTerminalContainer: View {
    @ObservedObject var tabManager: TerminalTabManager
    @ObservedObject var fileTabManager: RemoteFileTabManager
    @ObservedObject var storeManager: StoreManager
    @ObservedObject var viewTabConfig: ViewTabConfigurationManager
    let disconnectCoordinator: ServerConnectionLifecycleCoordinator
    let serverManager: ServerManager
    let fileBrowser: RemoteFileBrowserStore
    let server: Server
    @Binding var isZenModeEnabled: Bool
    let isSidebarVisible: Bool
    let onToggleSidebar: () -> Void

    @EnvironmentObject var ghosttyApp: Ghostty.App
    @Environment(\.colorScheme) private var colorScheme

    /// Theme name from settings
    @AppStorage(CloudKitSyncConstants.terminalThemeNameKey) private var terminalThemeName = "Aizen Dark"
    @AppStorage(CloudKitSyncConstants.terminalThemeNameLightKey) private var terminalThemeNameLight = "Aizen Light"
    @AppStorage(CloudKitSyncConstants.terminalUsePerAppearanceThemeKey) private var usePerAppearanceTheme = true

    /// Disconnect confirmation
    @State private var showingDisconnectConfirmation = false
    @State private var serverToEdit: Server?

    /// Tab limit alert
    @State private var showingTabLimitAlert = false
    @State private var showingFileTabLimitAlert = false
    @State private var showingSplitPaneUpgradeAlert = false
    @State private var showingZenPanel = false
    #if os(macOS)
    @State private var zenWindowSafeAreaInsets = EdgeInsets()
    #endif

    /// Selected view type - persisted per server
    private var selectedView: String {
        viewTabConfig.effectiveView(for: tabManager.selectedViewByServer[server.id])
    }

    private var visibleViewTabs: [ConnectionViewTab] {
        viewTabConfig.currentVisibleTabs
    }

    private var shouldShowViewPicker: Bool {
        visibleViewTabs.count > 1
    }

    private var effectiveThemeName: String {
        guard usePerAppearanceTheme else { return terminalThemeName }
        return colorScheme == .dark ? terminalThemeName : terminalThemeNameLight
    }

    private var selectedViewBinding: Binding<String> {
        Binding(
            get: { viewTabConfig.effectiveView(for: tabManager.selectedViewByServer[server.id]) },
            set: { newValue in
                let current = viewTabConfig.effectiveView(for: tabManager.selectedViewByServer[server.id])
                guard current != newValue else { return }
                DispatchQueue.main.async {
                    tabManager.selectedViewByServer[server.id] = viewTabConfig.isTabVisible(newValue)
                        ? newValue
                        : viewTabConfig.effectiveDefaultTab()
                }
            }
        )
    }

    /// Tabs for THIS server only
    private var serverTabs: [TerminalTab] {
        tabManager.tabs(for: server.id)
    }

    /// Selected tab ID for this server
    private var selectedTabId: UUID? {
        tabManager.selectedTabByServer[server.id]
    }

    private var selectedTabIdBinding: Binding<UUID?> {
        Binding(
            get: { tabManager.selectedTabByServer[server.id] },
            set: { newValue in
                let current = tabManager.selectedTabByServer[server.id]
                guard current != newValue else { return }
                DispatchQueue.main.async {
                    tabManager.selectedTabByServer[server.id] = newValue
                }
            }
        )
    }

    /// Currently selected tab
    private var selectedTab: TerminalTab? {
        guard let id = selectedTabId else { return serverTabs.first }
        return serverTabs.first { $0.id == id } ?? serverTabs.first
    }

    private var serverFileTabs: [RemoteFileTab] {
        fileTabManager.tabs(for: server.id)
    }

    private var selectedFileTabId: UUID? {
        fileTabManager.selectedTab(for: server.id)?.id
    }

    private var selectedFileTabIdBinding: Binding<UUID?> {
        Binding(
            get: { selectedFileTabId },
            set: { newValue in
                guard let newValue,
                      let tab = serverFileTabs.first(where: { $0.id == newValue }) else {
                    return
                }
                fileTabManager.selectTab(tab)
            }
        )
    }

    private var selectedFileTab: RemoteFileTab? {
        fileTabManager.selectedTab(for: server.id)
    }

    private var tmuxAttachPromptBinding: Binding<TmuxAttachPrompt?> {
        Binding(
            get: {
                guard let prompt = tabManager.tmuxAttachPrompt else { return nil }
                guard tabManager.paneStates[prompt.id]?.serverId == server.id else { return nil }
                return prompt
            },
            set: { newValue in
                guard newValue == nil, let prompt = tabManager.tmuxAttachPrompt else { return }
                guard tabManager.paneStates[prompt.id]?.serverId == server.id else { return }
                tabManager.cancelTmuxAttachPrompt(paneId: prompt.id)
            }
        )
    }

    private var macOSZenTerminalContentInsets: EdgeInsets {
        #if os(macOS)
        return isZenModeEnabled ? zenWindowSafeAreaInsets : EdgeInsets()
        #else
        return EdgeInsets()
        #endif
    }

    private var liveTerminalBackgroundColor: Color {
        let resolved = TerminalThemeBackgroundResolver.resolve(
            themeName: effectiveThemeName,
            fallbackHex: terminalBackgroundFallbackHex
        )
        return resolved.usedFallback ? platformFallbackBackgroundColor : resolved.color
    }

    private var terminalBackgroundFallbackHex: String {
        colorScheme == .dark ? "#000000" : "#FFFFFF"
    }

    private var platformFallbackBackgroundColor: Color {
        #if os(iOS)
        return Color(UIColor.systemBackground)
        #elseif os(macOS)
        return Color(NSColor.windowBackgroundColor)
        #else
        return .black
        #endif
    }

    private var sharedBody: some View {
        contentLayer
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(liveTerminalBackgroundColor)
            .overlay(alignment: .top) {
                #if os(macOS)
                if !isZenModeEnabled {
                    MacOSToolbarBackdrop(color: liveTerminalBackgroundColor)
                }
                #endif
            }
            .background {
                #if os(macOS)
                if isZenModeEnabled {
                    MacOSZenWindowChromeBridge(contentInsets: $zenWindowSafeAreaInsets)
                        .frame(width: 0, height: 0)
                }
                #endif
            }
            .macOSZenExpandedTopSafeArea(isZenModeEnabled && selectedView == "terminal")
            .onAppear {
                updateTerminalBackgroundColor()
                // Select first tab if none selected
                if selectedTabId == nil {
                    selectedTabIdBinding.wrappedValue = serverTabs.first?.id
                }
                ensureInitialFileTabIfNeeded()
            }
            .onChange(of: terminalThemeName) { _ in
                updateTerminalBackgroundColor()
            }
            .onChange(of: terminalThemeNameLight) { _ in
                updateTerminalBackgroundColor()
            }
            .onChange(of: usePerAppearanceTheme) { _ in
                updateTerminalBackgroundColor()
            }
            .onChange(of: colorScheme) { _ in
                updateTerminalBackgroundColor()
            }
            .onChange(of: selectedView) { _ in
                ensureInitialFileTabIfNeeded()
            }
            .onChange(of: serverTabs.count) { _ in
                // Auto-select if current selection is invalid
                if let currentId = selectedTabId, !serverTabs.contains(where: { $0.id == currentId }) {
                    selectedTabIdBinding.wrappedValue = serverTabs.first?.id
                }
            }
            .onChange(of: isZenModeEnabled) { newValue in
                if !newValue {
                    showingZenPanel = false
                }
            }
            .limitReachedAlert(.tabs, isPresented: $showingTabLimitAlert)
            .limitReachedAlert(.fileTabs, isPresented: $showingFileTabLimitAlert)
            .splitPaneProFeatureAlert(isPresented: $showingSplitPaneUpgradeAlert)
            .sheet(item: tmuxAttachPromptBinding) { prompt in
                TmuxAttachPromptSheet(
                    prompt: prompt,
                    onConfirm: { selection in
                        tabManager.resolveTmuxAttachPrompt(paneId: prompt.id, selection: selection)
                    }
                )
            }
    }

    @ViewBuilder
    private var contentLayer: some View {
        ZStack {
            // Stats view - always in hierarchy, visibility controlled by opacity
            // Pass isVisible to pause/resume collection when hidden
            ServerStatsView(
                server: server,
                isVisible: selectedView == "stats",
                backgroundColor: liveTerminalBackgroundColor,
                borrowedLeaseProvider: { tabManager.sharedStatsLease(for: server.id) },
                statsCollector: ServerStatsCollector(connectionProvider: StatsSSHConnectionProvider.makeProvider())
            )
                .opacity(selectedView == "stats" ? 1 : 0)
                .allowsHitTesting(selectedView == "stats")
                .zIndex(selectedView == "stats" ? 1 : 0)

            if selectedView == "files" {
                if let selectedFileTab {
                    RemoteFileBrowserScreen(
                        browser: fileBrowser,
                        server: server,
                        fileTab: selectedFileTab,
                        initialPath: selectedFileTab.seedPath
                    ) { currentPath in
                        fileTabManager.updateLastKnownPath(currentPath, for: selectedFileTab.id)
                    }
                    .id(selectedFileTab.id)
                    .zIndex(1)
                } else {
                    RemoteFileTabsEmptyState {
                        openNewFileTab(selectFilesViewOnSuccess: false)
                    }
                    .zIndex(1)
                }
            }

            #if os(macOS)
            // Each tab is an isolated terminal view
            ForEach(serverTabs, id: \.id) { tab in
                let isVisible = selectedView == "terminal" && selectedTabId == tab.id
                TerminalTabView(
                    tab: tab,
                    server: server,
                    tabManager: tabManager,
                    storeManager: storeManager,
                    isSelected: isVisible
                )
                .padding(macOSZenTerminalContentInsets)
                .opacity(isVisible ? 1 : 0)
                .allowsHitTesting(isVisible)
                .zIndex(isVisible ? 1 : 0)
            }

            // Empty state when in terminal view with no tabs
            if selectedView == "terminal" && serverTabs.isEmpty {
                TerminalEmptyStateView(server: server) {
                    openNewTab()
                }
                .padding(macOSZenTerminalContentInsets)
            }
            #else
            if selectedView == "terminal" && serverTabs.isEmpty {
                TerminalEmptyStateView(server: server) {
                    openNewTab()
                }
            }
            #endif
        }
    }

    var body: some View {
        #if os(macOS)
        macOSBody
        #else
        sharedBody
        #endif
    }

    private func handleNewTabCommand() {
        if selectedView == ConnectionViewTab.files.id {
            openNewFileTab(selectFilesViewOnSuccess: true)
        } else {
            openNewTab(selectTerminalViewOnSuccess: true)
        }
    }

    private func ensureInitialFileTabIfNeeded() {
        guard selectedView == ConnectionViewTab.files.id else { return }

        let seedPath = selectedTab.flatMap { tabManager.workingDirectory(for: $0.focusedPaneId) }
        guard let fileTab = fileTabManager.ensureInitialTab(for: server, seedPath: seedPath) else { return }
        fileBrowser.prepareNewTab(fileTab, duplicating: nil)
    }

    private func openNewTab(selectTerminalViewOnSuccess: Bool = false) {
        guard tabManager.canOpenNewTab else {
            showingTabLimitAlert = true
            return
        }

        tabManager.requestTabOpen(
            for: server,
            onOpened: { tab in
                if selectTerminalViewOnSuccess {
                    tabManager.selectedViewByServer[server.id] = viewTabConfig.isTabVisible(ConnectionViewTab.terminal.id)
                        ? ConnectionViewTab.terminal.id
                        : viewTabConfig.effectiveDefaultTab()
                }
                selectedTabIdBinding.wrappedValue = tab.id
            }
        )
    }

    private func openNewFileTab(selectFilesViewOnSuccess: Bool = false) {
        guard fileTabManager.canOpenNewTab(for: server.id) else {
            showingFileTabLimitAlert = true
            return
        }

        let plan = RemoteFileTabOpeningPolicy.newTabPlan(
            selectedFileTab: selectedFileTab,
            selectedFileTabLastVisitedPath: selectedFileTab.flatMap { fileBrowser.lastVisitedPath(for: $0) },
            fallbackWorkingDirectory: selectedTab.flatMap { tabManager.workingDirectory(for: $0.focusedPaneId) }
        )
        let newTab = plan.sourceTab.flatMap { fileTabManager.duplicateTab($0, seedPath: plan.seedPath) }
            ?? fileTabManager.openTab(for: server, seedPath: plan.seedPath)

        guard let newTab else { return }
        fileBrowser.prepareNewTab(newTab, duplicating: plan.sourceTab)

        if selectFilesViewOnSuccess {
            tabManager.selectedViewByServer[server.id] = viewTabConfig.isTabVisible(ConnectionViewTab.files.id)
                ? ConnectionViewTab.files.id
                : viewTabConfig.effectiveDefaultTab()
        }
    }

    private func selectPreviousTab() {
        guard let currentId = selectedTabId,
              let currentIndex = serverTabs.firstIndex(where: { $0.id == currentId }),
              currentIndex > 0 else { return }
        selectedTabIdBinding.wrappedValue = serverTabs[currentIndex - 1].id
    }

    private func selectNextTab() {
        guard let currentId = selectedTabId,
              let currentIndex = serverTabs.firstIndex(where: { $0.id == currentId }),
              currentIndex < serverTabs.count - 1 else { return }
        selectedTabIdBinding.wrappedValue = serverTabs[currentIndex + 1].id
    }

    private func selectPreviousFileTab() {
        fileTabManager.selectPreviousTab(for: server.id)
    }

    private func selectNextFileTab() {
        fileTabManager.selectNextTab(for: server.id)
    }

    private func baseFileTabTitle(for tab: RemoteFileTab) -> String {
        RemoteFileTabTitlePolicy.baseTitle(
            for: fileTabTitleInput(for: tab),
            serverName: server.name.nonEmptyString
        )
    }

    private func displayedFileTabTitle(for tab: RemoteFileTab) -> String {
        let resolvedTitles = RemoteFileTabTitlePolicy.displayedTitles(
            for: serverFileTabs.map { fileTabTitleInput(for: $0) },
            serverName: server.name.nonEmptyString
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

    private func closeSelectedFileTab() {
        guard let selectedFileTab,
              let removedTab = fileTabManager.closeTab(selectedFileTab) else {
            return
        }
        fileBrowser.removeState(for: removedTab.id)
    }

    private func serverViewTabActions() -> ServerViewTabActions {
        ServerViewTabActions(
            openNew: handleNewTabCommand,
            closeSelected: {
                if selectedView == ConnectionViewTab.files.id {
                    closeSelectedFileTab()
                } else if let selectedTab {
                    tabManager.closeTab(selectedTab)
                }
            },
            selectPrevious: {
                if selectedView == ConnectionViewTab.files.id {
                    selectPreviousFileTab()
                } else {
                    selectPreviousTab()
                }
            },
            selectNext: {
                if selectedView == ConnectionViewTab.files.id {
                    selectNextFileTab()
                } else {
                    selectNextTab()
                }
            }
        )
    }

    private func updateTerminalBackgroundColor() {
        let resolved = TerminalThemeBackgroundResolver.resolve(
            themeName: effectiveThemeName,
            fallbackHex: terminalBackgroundFallbackHex
        )
        TerminalThemeBackgroundResolver.cacheResolvedBackground(resolved)
    }

    // MARK: - Toolbar Items (macOS)

    #if os(macOS)
    private var macOSBody: some View {
        sharedBody
            .focusedValue(\.openTerminalTab, handleNewTabCommand)
            .focusedValue(\.serverViewTabActions, serverViewTabActions())
            .toolbar {
                ConnectionTabsToolbarContent(
                    selectedView: selectedView,
                    shouldShowViewPicker: shouldShowViewPicker,
                    visibleViewTabs: visibleViewTabs,
                    selectedViewBinding: selectedViewBinding,
                    isZenModeEnabled: $isZenModeEnabled,
                    showingZenPanel: $showingZenPanel,
                    serverName: server.name,
                    statusText: tabsStatusText,
                    statusColor: zenIndicatorColor,
                    terminalTabs: serverTabs,
                    selectedTerminalTabId: selectedTabIdBinding,
                    terminalTabTitle: { tabManager.displayTitle(for: $0) },
                    paneState: { tab in tabManager.paneStates[tab.focusedPaneId] },
                    tabManager: tabManager,
                    onCloseTerminalTab: { tabManager.closeTab($0) },
                    onNewTerminalTab: { selectTerminalViewOnSuccess in
                        openNewTab(selectTerminalViewOnSuccess: selectTerminalViewOnSuccess)
                    },
                    onPreviousTerminalTab: selectPreviousTab,
                    onNextTerminalTab: selectNextTab,
                    fileTabs: serverFileTabs,
                    selectedFileTabId: selectedFileTabIdBinding,
                    fileTabTitle: displayedFileTabTitle(for:),
                    selectedFileTab: selectedFileTab,
                    filesCurrentPath: selectedFileTab.map { fileBrowser.currentPath(for: $0) } ?? "/",
                    areHiddenFilesVisible: selectedFileTab.map { fileBrowser.showHiddenFiles(for: $0) } ?? false,
                    filesShowHiddenBinding: Binding(
                        get: { selectedFileTab.map { fileBrowser.showHiddenFiles(for: $0) } ?? false },
                        set: { newValue in
                            guard let selectedFileTab else { return }
                            fileBrowser.setShowHiddenFiles(newValue, for: selectedFileTab)
                        }
                    ),
                    canFilesGoUp: selectedFileTab.map { fileBrowser.currentPath(for: $0) != "/" } ?? false,
                    onSelectFileTab: { fileTabManager.selectTab($0) },
                    onCloseFileTab: { tab in
                        if let removedTab = fileTabManager.closeTab(tab) {
                            fileBrowser.removeState(for: removedTab.id)
                        }
                    },
                    onCloseOtherFileTabs: { tab in
                        for removedTab in fileTabManager.closeOtherTabs(except: tab) {
                            fileBrowser.removeState(for: removedTab.id)
                        }
                    },
                    onCloseFileTabsToLeft: { tab in
                        for removedTab in fileTabManager.closeTabsToLeft(of: tab) {
                            fileBrowser.removeState(for: removedTab.id)
                        }
                    },
                    onCloseFileTabsToRight: { tab in
                        for removedTab in fileTabManager.closeTabsToRight(of: tab) {
                            fileBrowser.removeState(for: removedTab.id)
                        }
                    },
                    onDuplicateFileTab: { tab in
                        guard fileTabManager.canOpenNewTab(for: server.id) else {
                            showingFileTabLimitAlert = true
                            return
                        }

                        let seedPath = fileBrowser.lastVisitedPath(for: tab)
                        guard let duplicate = fileTabManager.duplicateTab(tab, seedPath: seedPath) else { return }
                        fileBrowser.prepareNewTab(duplicate, duplicating: tab)
                    },
                    onNewFileTab: { selectFilesViewOnSuccess in
                        openNewFileTab(selectFilesViewOnSuccess: selectFilesViewOnSuccess)
                    },
                    onPreviousFileTab: selectPreviousFileTab,
                    onNextFileTab: selectNextFileTab,
                    onFilesGoUp: {
                        guard let selectedFileTab else { return }
                        fileBrowser.requestNavigation(.goUp, in: selectedFileTab, server: server)
                    },
                    onFilesRefresh: {
                        guard let selectedFileTab else { return }
                        fileBrowser.requestNavigation(.refresh, in: selectedFileTab, server: server)
                    },
                    onFilesUpload: {
                        guard let selectedFileTab else { return }
                        let currentPath = fileBrowser.currentPath(for: selectedFileTab)
                        fileBrowser.requestUploadPicker(for: selectedFileTab, destinationPath: currentPath)
                    },
                    onFilesCreateFolder: {
                        guard let selectedFileTab else { return }
                        let currentPath = fileBrowser.currentPath(for: selectedFileTab)
                        fileBrowser.requestCreateFolder(for: selectedFileTab, destinationPath: currentPath)
                    },
                    canSplit: selectedTab != nil,
                    canClosePane: selectedTab != nil,
                    onSplitRight: { splitFocusedPane(.horizontal) },
                    onSplitDown: { splitFocusedPane(.vertical) },
                    onClosePane: {
                        guard let selectedTab else { return }
                        tabManager.closePane(tab: selectedTab, paneId: selectedTab.focusedPaneId)
                    },
                    isSidebarVisible: isSidebarVisible,
                    onToggleSidebar: onToggleSidebar,
                    onShowSettings: { SettingsWindowManager.shared.show() },
                    onEditServer: { serverToEdit = server },
                    onRequestDisconnect: { showingDisconnectConfirmation = true }
                )
            }
            .alert(
                disconnectAlertTitle,
                isPresented: $showingDisconnectConfirmation,
            ) {
                Button("Cancel", role: .cancel) {}
                Button(disconnectActionTitle, role: .destructive) {
                    disconnectFromServer()
                }
                .keyboardShortcut(.defaultAction)
            } message: {
                Text(disconnectAlertMessage)
            }
            .sheet(item: $serverToEdit) { editingServer in
                ServerFormSheet(
                    serverManager: serverManager,
                    storeManager: storeManager,
                    workspace: serverManager.workspaces.first { $0.id == editingServer.workspaceId },
                    server: editingServer,
                    onSave: { _ in
                        serverToEdit = nil
                    }
                )
                .frame(
                    minWidth: 640,
                    idealWidth: 700,
                    maxWidth: 760,
                    minHeight: 520,
                    idealHeight: 620,
                    maxHeight: 680
                )
            }
    }

    private func disconnectFromServer() {
        disconnectCoordinator.requestServerDisconnect(
            serverId: server.id,
            disconnectRemoteFiles: { serverId in
                fileBrowser.disconnect(serverId: serverId)
            },
            disconnectFileTabs: { serverId in
                fileTabManager.disconnect(serverId: serverId)
            },
            disconnectTerminals: tabManager.disconnectServerAndWait
        )
    }

    private func splitFocusedPane(_ direction: TerminalSplitDirection) {
        guard let selectedTab else { return }
        guard storeManager.isPro else {
            showingZenPanel = false
            showingSplitPaneUpgradeAlert = true
            return
        }

        switch direction {
        case .horizontal:
            _ = tabManager.splitHorizontal(tab: selectedTab, paneId: selectedTab.focusedPaneId)
        case .vertical:
            _ = tabManager.splitVertical(tab: selectedTab, paneId: selectedTab.focusedPaneId)
        }
    }
    #endif
}

#if os(macOS)
private extension ConnectionTerminalContainer {
    var zenIndicatorColor: Color {
        guard let state = selectedTab.flatMap({ tabManager.paneStates[$0.focusedPaneId] }) else {
            if selectedView == ConnectionViewTab.files.id {
                return serverFileTabs.isEmpty ? .secondary : .green
            }
            return serverTabs.isEmpty ? .secondary : .green
        }

        switch state.connectionState {
        case .connected:
            return .green
        case .connecting, .reconnecting:
            return .orange
        case .disconnected, .idle:
            return .secondary
        case .failed:
            return .red
        }
    }

    var tabsStatusText: String {
        let count = selectedView == ConnectionViewTab.files.id ? serverFileTabs.count : serverTabs.count

        if selectedView == ConnectionViewTab.files.id {
            if count == 0 {
                return String(localized: "No file tabs")
            }

            return count == 1
                ? String(localized: "1 file tab")
                : String(format: String(localized: "%lld file tabs"), Int64(count))
        }

        if count == 0 {
            return String(localized: "No terminals")
        }

        return count == 1
            ? String(localized: "1 tab")
            : String(format: String(localized: "%lld tabs"), Int64(count))
    }

    var compactTabsStatusText: String {
        let count = selectedView == ConnectionViewTab.files.id ? serverFileTabs.count : serverTabs.count

        if selectedView == ConnectionViewTab.files.id {
            return count == 1
                ? String(localized: "1 file tab")
                : String(format: String(localized: "%lld file tabs"), Int64(count))
        }

        return count == 1
            ? String(localized: "1 tab")
            : String(format: String(localized: "%lld tabs"), Int64(count))
    }

    var disconnectAlertTitle: String {
        String(localized: "Close Tab?")
    }

    var disconnectActionTitle: String {
        String(localized: "Close")
    }

    var disconnectAlertMessage: String {
        let terminalCount = serverTabs.count
        let fileCount = serverFileTabs.count

        if terminalCount == 0, fileCount == 0 {
            return String(localized: "This will return to the server list.")
        }

        if terminalCount > 0, fileCount > 0 {
            return String(localized: "All terminal and file tabs for this server will be closed.")
        }

        if fileCount > 0 {
            return String(localized: "All file tabs for this server will be closed.")
        }

        return String(localized: "All terminal tabs for this server will be closed.")
    }
}
#endif
