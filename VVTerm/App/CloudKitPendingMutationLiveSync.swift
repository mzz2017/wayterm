import Foundation

enum CloudKitPendingMutationLiveSync {
    @MainActor
    static func sync(_ mutation: PendingCloudKitMutation) async throws {
        switch (mutation.entity, mutation.operation) {
        case (.server, .upsert):
            if let server = try mutation.decodedPayload(as: Server.self) {
                try await CloudKitManager.shared.saveServer(server)
            }
        case (.server, .delete):
            if let server = try mutation.decodedPayload(as: Server.self) {
                try await CloudKitManager.shared.deleteServer(server)
            }
        case (.workspace, .upsert):
            if let workspace = try mutation.decodedPayload(as: Workspace.self) {
                try await CloudKitManager.shared.saveWorkspace(workspace)
            }
        case (.workspace, .delete):
            if let workspace = try mutation.decodedPayload(as: Workspace.self) {
                try await CloudKitManager.shared.deleteWorkspace(workspace)
            }
        case (.terminalTheme, .upsert), (.terminalTheme, .delete):
            if let theme = try mutation.decodedPayload(as: TerminalTheme.self) {
                try await CloudKitManager.shared.saveTerminalTheme(theme)
            }
        case (.terminalThemePreference, .upsert):
            if let preference = try mutation.decodedPayload(as: TerminalThemePreference.self) {
                try await CloudKitManager.shared.saveTerminalThemePreference(preference)
            }
        case (.terminalThemePreference, .delete):
            break
        case (.terminalAccessoryProfile, .upsert):
            if let profile = try mutation.decodedPayload(as: TerminalAccessoryProfile.self) {
                let resolvedProfile = try await CloudKitManager.shared.syncTerminalAccessoryProfile(profile)
                NotificationCenter.default.post(
                    name: TerminalAccessoryCloudResolutionNotification.didResolve,
                    object: CloudKitSyncCoordinator.shared,
                    userInfo: ["profile": resolvedProfile]
                )
            }
        case (.terminalAccessoryProfile, .delete):
            break
        }
    }
}
