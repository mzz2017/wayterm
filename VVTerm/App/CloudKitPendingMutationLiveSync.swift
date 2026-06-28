import CloudKit
import Foundation

enum CloudKitPendingMutationLiveSync {
    @MainActor
    static func sync(_ mutation: PendingCloudKitMutation) async throws {
        switch (mutation.entity, mutation.operation) {
        case (.server, .upsert):
            if let server = try mutation.decodedPayload(as: Server.self) {
                try await CloudKitManager.shared.saveCloudKitRecord(
                    server.toRecord(in: CloudKitManager.shared.recordZoneID),
                    successLog: "Saved server \(server.name) to CloudKit",
                    failureLog: "Failed to save server"
                )
            }
        case (.server, .delete):
            if let server = try mutation.decodedPayload(as: Server.self) {
                try await CloudKitManager.shared.deleteCloudKitRecord(
                    named: server.id.uuidString,
                    successLog: "Deleted server \(server.name) from CloudKit",
                    failureLog: "Failed to delete server"
                )
            }
        case (.workspace, .upsert):
            if let workspace = try mutation.decodedPayload(as: Workspace.self) {
                try await CloudKitManager.shared.saveCloudKitRecord(
                    workspace.toRecord(in: CloudKitManager.shared.recordZoneID),
                    successLog: "Saved workspace \(workspace.name) to CloudKit",
                    failureLog: "Failed to save workspace"
                )
            }
        case (.workspace, .delete):
            if let workspace = try mutation.decodedPayload(as: Workspace.self) {
                try await CloudKitManager.shared.deleteCloudKitRecord(
                    named: workspace.id.uuidString,
                    successLog: "Deleted workspace \(workspace.name) from CloudKit",
                    failureLog: "Failed to delete workspace"
                )
            }
        case (.terminalTheme, .upsert), (.terminalTheme, .delete):
            if let theme = try mutation.decodedPayload(as: TerminalTheme.self) {
                try await CloudKitManager.shared.saveCloudKitRecord(
                    theme.toRecord(in: CloudKitManager.shared.recordZoneID),
                    successLog: "Saved terminal theme \(theme.name) to CloudKit",
                    failureLog: "Failed to save terminal theme"
                )
            }
        case (.terminalThemePreference, .upsert):
            if let preference = try mutation.decodedPayload(as: TerminalThemePreference.self) {
                try await CloudKitManager.shared.saveCloudKitRecord(
                    preference.toRecord(in: CloudKitManager.shared.recordZoneID),
                    successLog: "Saved terminal theme preference to CloudKit",
                    failureLog: "Failed to save terminal theme preference"
                )
            }
        case (.terminalThemePreference, .delete):
            break
        case (.terminalAccessoryProfile, .upsert):
            if let profile = try mutation.decodedPayload(as: TerminalAccessoryProfile.self) {
                let profileSync = TerminalAccessoryCloudKitProfileSyncService(cloudKit: CloudKitManager.shared)
                let resolvedProfile = try await profileSync.syncTerminalAccessoryProfile(profile)
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
