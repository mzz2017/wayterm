import Foundation

struct CloudKitChanges {
    let servers: [Server]
    let workspaces: [Workspace]
    let deletedServerIDs: [UUID]
    let deletedWorkspaceIDs: [UUID]
    let isFullFetch: Bool
}

@MainActor
protocol ServerCloudSyncing {
    var isAvailable: Bool { get }

    func fetchChanges(forceFullFetch: Bool) async throws -> CloudKitChanges
    func saveServer(_ server: Server) async throws
    func saveWorkspace(_ workspace: Workspace) async throws
    func isSchemaError(_ error: Error) -> Bool
}

@MainActor
protocol ServerPendingCloudSyncCoordinating {
    func snapshot() -> [PendingCloudKitMutation]
    func clearPendingMutations(for entities: Set<PendingCloudKitEntity>)
    func removePendingMutation(_ mutationID: UUID)
    func enqueueServerUpsert(_ server: Server)
    func enqueueServerDelete(_ server: Server)
    func enqueueWorkspaceUpsert(_ workspace: Workspace)
    func enqueueWorkspaceDelete(_ workspace: Workspace)
    func drainPendingMutations() async
}

@MainActor
final class DisabledServerCloudSyncService: ServerCloudSyncing {
    var isAvailable: Bool { false }

    func fetchChanges(forceFullFetch: Bool) async throws -> CloudKitChanges {
        throw CloudKitError.notAvailable
    }

    func saveServer(_ server: Server) async throws {
        throw CloudKitError.notAvailable
    }

    func saveWorkspace(_ workspace: Workspace) async throws {
        throw CloudKitError.notAvailable
    }

    func isSchemaError(_ error: Error) -> Bool {
        false
    }
}

@MainActor
final class NoopServerPendingCloudSyncCoordinator: ServerPendingCloudSyncCoordinating {
    func snapshot() -> [PendingCloudKitMutation] {
        []
    }

    func clearPendingMutations(for entities: Set<PendingCloudKitEntity>) {}

    func removePendingMutation(_ mutationID: UUID) {}

    func enqueueServerUpsert(_ server: Server) {}

    func enqueueServerDelete(_ server: Server) {}

    func enqueueWorkspaceUpsert(_ workspace: Workspace) {}

    func enqueueWorkspaceDelete(_ workspace: Workspace) {}

    func drainPendingMutations() async {}
}
