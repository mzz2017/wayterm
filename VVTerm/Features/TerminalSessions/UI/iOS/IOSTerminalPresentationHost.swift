import SwiftUI
#if os(iOS)

extension View {
    func iosTerminalPresentation(
        isTabLimitPresented: Binding<Bool>,
        isFileTabLimitPresented: Binding<Bool>,
        isSettingsPresented: Binding<Bool>,
        serverToEdit: Binding<Server?>,
        serverManager: ServerManager,
        storeManager: StoreManager,
        tmuxAttachPrompt: Binding<TmuxAttachPrompt?>,
        onResolveTmuxAttachPrompt: @escaping (TmuxAttachPrompt, TmuxAttachSelection) -> Void,
        pendingCloseSession: Binding<ConnectionSession?>,
        onConfirmCloseSession: @escaping (ConnectionSession) -> Void,
        onCancelCloseSession: @escaping () -> Void
    ) -> some View {
        modifier(
            IOSTerminalPresentationHost(
                isTabLimitPresented: isTabLimitPresented,
                isFileTabLimitPresented: isFileTabLimitPresented,
                isSettingsPresented: isSettingsPresented,
                serverToEdit: serverToEdit,
                serverManager: serverManager,
                storeManager: storeManager,
                tmuxAttachPrompt: tmuxAttachPrompt,
                onResolveTmuxAttachPrompt: onResolveTmuxAttachPrompt,
                pendingCloseSession: pendingCloseSession,
                onConfirmCloseSession: onConfirmCloseSession,
                onCancelCloseSession: onCancelCloseSession
            )
        )
    }
}

private struct IOSTerminalPresentationHost: ViewModifier {
    @Binding var isTabLimitPresented: Bool
    @Binding var isFileTabLimitPresented: Bool
    @Binding var isSettingsPresented: Bool
    @Binding var serverToEdit: Server?
    @ObservedObject var serverManager: ServerManager
    @ObservedObject var storeManager: StoreManager
    @Binding var tmuxAttachPrompt: TmuxAttachPrompt?
    let onResolveTmuxAttachPrompt: (TmuxAttachPrompt, TmuxAttachSelection) -> Void
    @Binding var pendingCloseSession: ConnectionSession?
    let onConfirmCloseSession: (ConnectionSession) -> Void
    let onCancelCloseSession: () -> Void

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

    func body(content: Content) -> some View {
        content
            .limitReachedAlert(.tabs, isPresented: $isTabLimitPresented)
            .limitReachedAlert(.fileTabs, isPresented: $isFileTabLimitPresented)
            .sheet(isPresented: $isSettingsPresented) {
                SettingsView()
                    .modifier(AppearanceModifier())
            }
            .sheet(item: $serverToEdit) { server in
                NavigationStack {
                    ServerFormSheet(
                        serverManager: serverManager,
                        storeManager: storeManager,
                        workspace: serverManager.workspaces.first { $0.id == server.workspaceId },
                        server: server,
                        onSave: { _ in serverToEdit = nil }
                    )
                }
            }
            .sheet(item: $tmuxAttachPrompt) { prompt in
                TmuxAttachPromptSheet(
                    prompt: prompt,
                    onConfirm: { selection in
                        onResolveTmuxAttachPrompt(prompt, selection)
                    }
                )
            }
            .alert(
                String(localized: "Close Tab?"),
                isPresented: isCloseAlertPresented,
                presenting: pendingCloseSession
            ) { session in
                Button("Close", role: .destructive) {
                    onConfirmCloseSession(session)
                }
                Button("Cancel", role: .cancel) {
                    onCancelCloseSession()
                }
            } message: { session in
                Text(String(format: String(localized: "This will disconnect \"%@\"."), session.title))
            }
    }
}

#endif
