import SwiftUI
#if os(iOS)

struct IOSTerminalNavigationToolbar: ToolbarContent {
    let selectedView: String
    let shouldShowViewSwitcher: Bool
    let selectedViewBinding: Binding<String>?
    let visibleTabs: [ConnectionViewTab]
    let selectedServer: Server?
    let onBack: () -> Void
    let onOpenTerminalTab: () -> Void
    let onOpenFileTab: () -> Void
    let onOpenSettings: () -> Void
    let onShowFind: () -> Void
    let onEditServer: (Server) -> Void
    let onEnterZenMode: () -> Void
    let onDisconnect: () -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            Button {
                onBack()
            } label: {
                Image(systemName: "chevron.left")
            }
        }

        if shouldShowViewSwitcher {
            ToolbarItem(placement: .principal) {
                if let selectedViewBinding {
                    iOSNativeSegmentedPicker(
                        selection: selectedViewBinding,
                        tabs: visibleTabs
                    )
                    .fixedSize()
                }
            }
        }

        ToolbarItemGroup(placement: .navigationBarTrailing) {
            if selectedView == ConnectionViewTab.terminal.id {
                Button {
                    onOpenTerminalTab()
                } label: {
                    Image(systemName: "plus")
                }
            }

            if selectedView == ConnectionViewTab.files.id {
                Button {
                    onOpenFileTab()
                } label: {
                    Image(systemName: "plus")
                }
            }

            Menu {
                Button {
                    onOpenSettings()
                } label: {
                    Label("Settings", systemImage: "gear")
                }

                if selectedView == ConnectionViewTab.terminal.id {
                    Button {
                        onShowFind()
                    } label: {
                        Label("Find", systemImage: "magnifyingglass")
                    }
                }

                if let selectedServer {
                    Button {
                        onEditServer(selectedServer)
                    } label: {
                        Label("Edit Server", systemImage: "pencil")
                    }
                }

                Button {
                    onEnterZenMode()
                } label: {
                    Label("Zen Mode", systemImage: "arrow.up.left.and.arrow.down.right")
                }

                Button(role: .destructive) {
                    onDisconnect()
                } label: {
                    Label("Disconnect", systemImage: "xmark.circle")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }
}

#endif
