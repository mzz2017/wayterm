import CloudKit
import Foundation

@MainActor
final class ServerCloudKitSyncService: ServerCloudSyncing {
    private enum ServerRecordType {
        static let server = "Server"
        static let workspace = "Workspace"
    }

    private let cloudKit: CloudKitManager

    init(cloudKit: CloudKitManager) {
        self.cloudKit = cloudKit
    }

    var isAvailable: Bool {
        cloudKit.isAvailable
    }

    func fetchChanges(forceFullFetch: Bool) async throws -> CloudKitChanges {
        let changes = try await cloudKit.fetchRecordChanges(forceFullFetch: forceFullFetch)
        var servers: [Server] = []
        var workspaces: [Workspace] = []
        var deletedServerIDs: [UUID] = []
        var deletedWorkspaceIDs: [UUID] = []

        for record in changes.records {
            switch record.recordType {
            case ServerRecordType.server:
                if let server = Server(from: record) {
                    servers.append(server)
                }
            case ServerRecordType.workspace:
                if let workspace = Workspace(from: record) {
                    workspaces.append(workspace)
                }
            default:
                break
            }
        }

        for deletion in changes.deletions {
            switch deletion.recordType {
            case ServerRecordType.server:
                if let id = UUID(uuidString: deletion.recordID.recordName) {
                    deletedServerIDs.append(id)
                }
            case ServerRecordType.workspace:
                if let id = UUID(uuidString: deletion.recordID.recordName) {
                    deletedWorkspaceIDs.append(id)
                }
            default:
                break
            }
        }

        return CloudKitChanges(
            servers: servers,
            workspaces: workspaces,
            deletedServerIDs: deletedServerIDs,
            deletedWorkspaceIDs: deletedWorkspaceIDs,
            isFullFetch: changes.isFullFetch,
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
