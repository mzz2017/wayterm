//
//  ConnectionTabsToolbarContent.swift
//  Waterm
//

import SwiftUI

#if os(macOS)
struct ConnectionTabsToolbarContent: ToolbarContent {
    let selectedView: String
    let shouldShowViewPicker: Bool
    let visibleViewTabs: [ConnectionViewTab]
    @Binding var selectedViewBinding: String
    @Binding var isZenModeEnabled: Bool
    @Binding var showingZenPanel: Bool

    let serverName: String
    let statusText: String
    let statusColor: Color

    let terminalTabs: [TerminalTab]
    @Binding var selectedTerminalTabId: UUID?
    let terminalTabTitle: (TerminalTab) -> String
    let paneState: (TerminalTab) -> TerminalPaneState?
    @ObservedObject var tabManager: TerminalTabManager
    let onCloseTerminalTab: (TerminalTab) -> Void
    let onNewTerminalTab: (_ selectTerminalViewOnSuccess: Bool) -> Void
    let onPreviousTerminalTab: () -> Void
    let onNextTerminalTab: () -> Void

    let fileTabs: [RemoteFileTab]
    @Binding var selectedFileTabId: UUID?
    let fileTabTitle: (RemoteFileTab) -> String
    let selectedFileTab: RemoteFileTab?
    let filesCurrentPath: String
    let areHiddenFilesVisible: Bool
    @Binding var filesShowHiddenBinding: Bool
    let canFilesGoUp: Bool
    let onSelectFileTab: (RemoteFileTab) -> Void
    let onCloseFileTab: (RemoteFileTab) -> Void
    let onCloseOtherFileTabs: (RemoteFileTab) -> Void
    let onCloseFileTabsToLeft: (RemoteFileTab) -> Void
    let onCloseFileTabsToRight: (RemoteFileTab) -> Void
    let onDuplicateFileTab: (RemoteFileTab) -> Void
    let onNewFileTab: (_ selectFilesViewOnSuccess: Bool) -> Void
    let onPreviousFileTab: () -> Void
    let onNextFileTab: () -> Void
    let onFilesGoUp: () -> Void
    let onFilesRefresh: () -> Void
    let onFilesUpload: () -> Void
    let onFilesCreateFolder: () -> Void

    let canSplit: Bool
    let canClosePane: Bool
    let onSplitRight: () -> Void
    let onSplitDown: () -> Void
    let onClosePane: () -> Void

    let isSidebarVisible: Bool
    let onToggleSidebar: () -> Void
    let onShowSettings: () -> Void
    let onEditServer: () -> Void
    let onRequestDisconnect: () -> Void

    @ToolbarContentBuilder
    var body: some ToolbarContent {
        if !isZenModeEnabled {
            viewPickerToolbarItem
            if shouldShowTabsToolbar {
                tabsToolbarSpacer
                tabsToolbarItem
            }
            toolbarSpacer
            trailingToolbarItems
        } else {
            ToolbarItem(placement: .primaryAction) {
                zenModePanelToolbarButton
            }
        }
    }

    private var shouldShowTabsToolbar: Bool {
        (selectedView == ConnectionViewTab.terminal.id && !terminalTabs.isEmpty)
            || (selectedView == ConnectionViewTab.files.id && !fileTabs.isEmpty)
    }

    @ToolbarContentBuilder
    private var viewPickerToolbarItem: some ToolbarContent {
        if shouldShowViewPicker {
            ToolbarItem(placement: .navigation) {
                viewPickerControl
            }
        }
    }

    private var viewPickerControl: some View {
        Picker("View", selection: $selectedViewBinding) {
            ForEach(visibleViewTabs) { tab in
                Label(tab.localizedKey, systemImage: tab.icon)
                    .tag(tab.id)
            }
        }
        .pickerStyle(.segmented)
    }

    @ToolbarContentBuilder
    private var tabsToolbarSpacer: some ToolbarContent {
        adaptiveFixedToolbarSpacer(placement: .navigation)
    }

    @ToolbarContentBuilder
    private var tabsToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            if selectedView == ConnectionViewTab.files.id {
                RemoteFileTabsScrollView(
                    tabs: fileTabs,
                    selectedTabId: $selectedFileTabId,
                    titleForTab: fileTabTitle,
                    onSelect: onSelectFileTab,
                    onClose: onCloseFileTab,
                    onCloseOtherTabs: onCloseOtherFileTabs,
                    onCloseTabsToLeft: onCloseFileTabsToLeft,
                    onCloseTabsToRight: onCloseFileTabsToRight,
                    onDuplicate: onDuplicateFileTab,
                    onNew: { onNewFileTab(false) }
                )
            } else {
                TerminalTabsScrollView(
                    tabs: terminalTabs,
                    selectedTabId: $selectedTerminalTabId,
                    onClose: onCloseTerminalTab,
                    onNew: { onNewTerminalTab(false) },
                    tabManager: tabManager
                )
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarSpacer: some ToolbarContent {
        ToolbarItem(placement: .automatic) {
            Spacer()
        }
    }

    @ToolbarContentBuilder
    private var trailingToolbarItems: some ToolbarContent {
        if selectedView == ConnectionViewTab.files.id {
            ToolbarItem(placement: .primaryAction) {
                filesActionsToolbarButton
            }
        }

        ToolbarItem(placement: .primaryAction) {
            zenModeToolbarButton
        }

        ToolbarItem(placement: .primaryAction) {
            serverMenuToolbarButton
        }
    }

    private var zenModeToolbarButton: some View {
        Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                isZenModeEnabled = true
            }
        } label: {
            Label("Zen", systemImage: "arrow.up.left.and.arrow.down.right")
                .labelStyle(.iconOnly)
        }
        .help(Text("Enter Zen Mode"))
    }

    private var filesActionsToolbarButton: some View {
        Menu {
            Button {
                onFilesGoUp()
            } label: {
                Label("Parent", systemImage: "arrow.turn.up.left")
            }
            .disabled(selectedFileTab == nil || !canFilesGoUp)

            Button {
                onFilesRefresh()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(selectedFileTab == nil)

            Divider()

            Button {
                onFilesUpload()
            } label: {
                Label("Upload…", systemImage: "square.and.arrow.up")
            }
            .disabled(selectedFileTab == nil)

            Button {
                onFilesCreateFolder()
            } label: {
                Label("New Folder…", systemImage: "folder.badge.plus")
            }
            .disabled(selectedFileTab == nil)

            Button {
                filesShowHiddenBinding.toggle()
            } label: {
                Label(
                    areHiddenFilesVisible ? "Hide Hidden Files" : "Show Hidden Files",
                    systemImage: areHiddenFilesVisible ? "eye.slash" : "eye"
                )
            }
            .disabled(selectedFileTab == nil)

            Divider()

            Button {
                Clipboard.copy(filesCurrentPath)
            } label: {
                Label("Copy Path", systemImage: "document.on.document")
            }
        } label: {
            Label("Files", systemImage: "folder")
                .labelStyle(.titleAndIcon)
        }
        .help(Text("Files Menu"))
    }

    private var serverMenuToolbarButton: some View {
        Menu {
            Button {
                onShowSettings()
            } label: {
                Label("Settings", systemImage: "gear")
            }

            Button {
                onEditServer()
            } label: {
                Label("Edit Server", systemImage: "pencil")
            }

            Button(role: .destructive) {
                onRequestDisconnect()
            } label: {
                Label("Disconnect", systemImage: "xmark.circle")
            }
        } label: {
            Label("Server", systemImage: "ellipsis.circle")
                .labelStyle(.iconOnly)
        }
        .help(Text("Server Options"))
    }

    private var zenModePanelToolbarButton: some View {
        Button {
            withAnimation(.spring(response: 0.26, dampingFraction: 0.84)) {
                showingZenPanel.toggle()
            }
        } label: {
            Label("Zen", systemImage: "slider.horizontal.3")
                .labelStyle(.iconOnly)
        }
        .help(Text(showingZenPanel ? "Hide Zen controls" : "Show Zen controls"))
        .popover(isPresented: $showingZenPanel, arrowEdge: .top) {
            MacOSZenModePanel(
                width: 360,
                serverName: serverName,
                statusText: statusText,
                statusColor: statusColor,
                selectedView: selectedView,
                selectedViewBinding: $selectedViewBinding,
                viewTabs: visibleViewTabs,
                terminalTabs: terminalTabs,
                selectedTerminalTabId: $selectedTerminalTabId,
                terminalTabTitle: terminalTabTitle,
                paneState: paneState,
                fileTabs: fileTabs,
                selectedFileTabId: $selectedFileTabId,
                fileTabTitle: fileTabTitle,
                onPreviousTab: {
                    if selectedView == ConnectionViewTab.files.id {
                        onPreviousFileTab()
                    } else {
                        onPreviousTerminalTab()
                    }
                },
                onNextTab: {
                    if selectedView == ConnectionViewTab.files.id {
                        onNextFileTab()
                    } else {
                        onNextTerminalTab()
                    }
                },
                onNewTerminalTab: {
                    showingZenPanel = false
                    onNewTerminalTab(true)
                },
                onCloseTerminalTab: onCloseTerminalTab,
                onNewFileTab: {
                    showingZenPanel = false
                    onNewFileTab(true)
                },
                onCloseFileTab: onCloseFileTab,
                onSelectFileTab: onSelectFileTab,
                onSplitRight: onSplitRight,
                onSplitDown: onSplitDown,
                onClosePane: onClosePane,
                canSplit: canSplit,
                canClosePane: canClosePane,
                isSidebarVisible: isSidebarVisible,
                onToggleSidebar: {
                    showingZenPanel = false
                    onToggleSidebar()
                },
                onDisconnect: {
                    showingZenPanel = false
                    onRequestDisconnect()
                },
                canFilesGoUp: canFilesGoUp,
                filesShowHiddenBinding: $filesShowHiddenBinding,
                onFilesGoUp: onFilesGoUp,
                onFilesRefresh: onFilesRefresh,
                onExitZen: {
                    showingZenPanel = false
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                        isZenModeEnabled = false
                    }
                }
            )
        }
    }
}
#endif
