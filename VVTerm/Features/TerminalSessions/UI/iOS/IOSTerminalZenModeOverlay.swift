import SwiftUI
#if os(iOS)

struct IOSTerminalZenModeOverlay: View {
    @Binding var isPanelPresented: Bool

    let indicatorColor: Color?
    let serverName: String
    let selectedView: String
    let selectedViewBinding: Binding<String>
    let visibleTabs: [ConnectionViewTab]
    let sessions: [ConnectionSession]
    let selectedSessionId: Binding<UUID?>
    let sessionTitle: (ConnectionSession) -> String
    let onCloseSession: (ConnectionSession) -> Void
    let fileTabs: [RemoteFileTab]
    let selectedFileTabId: Binding<UUID?>
    let fileTabTitle: (RemoteFileTab) -> String
    let onSelectFileTab: (RemoteFileTab) -> Void
    let onCloseFileTab: (RemoteFileTab) -> Void
    let onNewTerminalTab: () -> Void
    let onNewFileTab: () -> Void
    let onOpenSettings: () -> Void
    let editableServer: Server?
    let onEditServer: (Server) -> Void
    let onDisconnect: () -> Void
    let onBack: () -> Void
    let onExitZen: () -> Void

    var body: some View {
        ZenModeFloatingOverlay(
            isPanelPresented: $isPanelPresented,
            indicatorColor: indicatorColor
        ) { panelWidth in
            IOSZenModePanel(
                width: panelWidth,
                serverName: serverName,
                selectedView: selectedView,
                selectedViewBinding: selectedViewBinding,
                viewTabs: visibleTabs,
                sessions: sessions,
                selectedSessionId: selectedSessionId,
                sessionTitle: sessionTitle,
                onCloseSession: onCloseSession,
                fileTabs: fileTabs,
                selectedFileTabId: selectedFileTabId,
                fileTabTitle: fileTabTitle,
                onSelectFileTab: onSelectFileTab,
                onCloseFileTab: onCloseFileTab,
                onNewTerminalTab: dismissing(onNewTerminalTab),
                onNewFileTab: dismissing(onNewFileTab),
                onOpenSettings: dismissing(onOpenSettings),
                onEditServer: editableServer.map { server in
                    dismissing {
                        onEditServer(server)
                    }
                },
                onDisconnect: dismissing(onDisconnect),
                onBack: dismissing(onBack),
                onExitZen: dismissing(onExitZen)
            )
        }
    }

    private func dismissing(_ action: @escaping () -> Void) -> () -> Void {
        {
            isPanelPresented = false
            action()
        }
    }
}

#endif
