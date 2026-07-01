import CloudKit
import Foundation

@MainActor
final class ServerCloudKitSyncService: ServerCloudSyncing {
    private let cloudKit: CloudKitManager

    init(cloudKit: CloudKitManager) {
        self.cloudKit = cloudKit
    }

    var isAvailable: Bool {
        cloudKit.isAvailable
    }

    func fetchChanges(forceFullFetch: Bool) async throws -> CloudKitChanges {
        let changes = try await cloudKit.fetchRecordChanges(forceFullFetch: forceFullFetch)
        return try ServerCloudKitChangeDecoder.decode(
            changes,
            commitFetchedChanges: { [cloudKit, token = changes.changeToken] in
                cloudKit.commitChangeToken(token)
            }
        )
    }

    func saveServer(_ server: Server) async throws {
        try await cloudKit.saveCloudKitRecord(
            server.toRecord(in: cloudKit.recordZoneID),
            successLog: "Saved server \(server.name) to CloudKit",
            failureLog: "Failed to save server"
        )
    }

    func saveWorkspace(_ workspace: Workspace) async throws {
        try await cloudKit.saveCloudKitRecord(
            workspace.toRecord(in: cloudKit.recordZoneID),
            successLog: "Saved workspace \(workspace.name) to CloudKit",
            failureLog: "Failed to save workspace"
        )
    }

    func isSchemaError(_ error: Error) -> Bool {
        CloudKitManager.isSchemaError(error)
    }
}

extension CloudKitSyncCoordinator: ServerPendingCloudSyncCoordinating {
    func enqueueServerUpsert(_ server: Server) {
        guard let payload = try? PendingCloudKitMutation.encodedPayload(for: server) else { return }
        enqueuePendingMutation(.upsert(entity: .server, entityKey: server.id.uuidString, payload: payload))
    }

    func enqueueServerDelete(_ server: Server) {
        guard let payload = try? PendingCloudKitMutation.encodedPayload(for: server) else { return }
        enqueuePendingMutation(.delete(entity: .server, entityKey: server.id.uuidString, payload: payload))
    }

    func enqueueWorkspaceUpsert(_ workspace: Workspace) {
        guard let payload = try? PendingCloudKitMutation.encodedPayload(for: workspace) else { return }
        enqueuePendingMutation(.upsert(entity: .workspace, entityKey: workspace.id.uuidString, payload: payload))
    }

    func enqueueWorkspaceDelete(_ workspace: Workspace) {
        guard let payload = try? PendingCloudKitMutation.encodedPayload(for: workspace) else { return }
        enqueuePendingMutation(.delete(entity: .workspace, entityKey: workspace.id.uuidString, payload: payload))
    }
}

extension ServerManager {
    static let shared = ServerManager()

    convenience init() {
        self.init(
            cloudKit: ServerCloudKitSyncService(cloudKit: CloudKitManager.shared),
            syncCoordinator: CloudKitSyncCoordinator.shared,
            localDataStore: UserDefaultsServerLocalDataStore(),
            isProProvider: { StoreManager.shared.isPro }
        )
    }
}
