import CloudKit
import Foundation

@MainActor
protocol PendingCloudKitRecordSyncing: AnyObject {
    var recordZoneID: CKRecordZone.ID { get }

    func savePendingCloudKitRecord(
        _ record: CKRecord,
        successLog: String,
        failureLog: String
    ) async throws

    func deletePendingCloudKitRecord(
        named recordName: String,
        successLog: String,
        failureLog: String
    ) async throws
}

extension CloudKitManager: PendingCloudKitRecordSyncing {
    func savePendingCloudKitRecord(
        _ record: CKRecord,
        successLog: String,
        failureLog: String
    ) async throws {
        try await saveCloudKitRecord(
            record,
            successLog: successLog,
            failureLog: failureLog
        )
    }

    func deletePendingCloudKitRecord(
        named recordName: String,
        successLog: String,
        failureLog: String
    ) async throws {
        try await deleteCloudKitRecord(
            named: recordName,
            successLog: successLog,
            failureLog: failureLog
        )
    }
}

enum CloudKitPendingMutationLiveSync {
    @MainActor
    static func sync(_ mutation: PendingCloudKitMutation) async throws {
        try await sync(mutation, cloudKit: CloudKitManager.shared)
    }

    @MainActor
    static func sync(
        _ mutation: PendingCloudKitMutation,
        cloudKit: PendingCloudKitRecordSyncing
    ) async throws {
        switch (mutation.entity, mutation.operation) {
        case (.server, .upsert):
            if let server = try mutation.decodedPayload(as: Server.self) {
                try await cloudKit.savePendingCloudKitRecord(
                    server.toRecord(in: cloudKit.recordZoneID),
                    successLog: "Saved server \(server.name) to CloudKit",
                    failureLog: "Failed to save server"
                )
            }
        case (.server, .delete):
            try await cloudKit.deletePendingCloudKitRecord(
                named: mutation.entityKey,
                successLog: "Deleted server \(mutation.entityKey) from CloudKit",
                failureLog: "Failed to delete server"
            )
        case (.workspace, .upsert):
            if let workspace = try mutation.decodedPayload(as: Workspace.self) {
                try await cloudKit.savePendingCloudKitRecord(
                    workspace.toRecord(in: cloudKit.recordZoneID),
                    successLog: "Saved workspace \(workspace.name) to CloudKit",
                    failureLog: "Failed to save workspace"
                )
            }
        case (.workspace, .delete):
            try await cloudKit.deletePendingCloudKitRecord(
                named: mutation.entityKey,
                successLog: "Deleted workspace \(mutation.entityKey) from CloudKit",
                failureLog: "Failed to delete workspace"
            )
        case (.terminalTheme, .upsert), (.terminalTheme, .delete):
            if let theme = try mutation.decodedPayload(as: TerminalTheme.self) {
                try await cloudKit.savePendingCloudKitRecord(
                    theme.toRecord(in: cloudKit.recordZoneID),
                    successLog: "Saved terminal theme \(theme.name) to CloudKit",
                    failureLog: "Failed to save terminal theme"
                )
            }
        case (.terminalThemePreference, .upsert):
            if let preference = try mutation.decodedPayload(as: TerminalThemePreference.self) {
                try await cloudKit.savePendingCloudKitRecord(
                    preference.toRecord(in: cloudKit.recordZoneID),
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
