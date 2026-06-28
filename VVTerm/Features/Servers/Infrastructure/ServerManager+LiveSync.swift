import Foundation

extension CloudKitManager: ServerCloudSyncing {
    func isSchemaError(_ error: Error) -> Bool {
        Self.isSchemaError(error)
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
            cloudKit: CloudKitManager.shared,
            syncCoordinator: CloudKitSyncCoordinator.shared,
            localDataStore: UserDefaultsServerLocalDataStore(),
            isProProvider: { StoreManager.shared.isPro }
        )
    }
}
