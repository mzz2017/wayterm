import Foundation

nonisolated struct CloudKitChanges {
    let servers: [Server]
    let workspaces: [Workspace]
    let deletedServerIDs: [UUID]
    let deletedWorkspaceIDs: [UUID]
    let isFullFetch: Bool
    private let commitHandler: (@MainActor () async -> Void)?

    init(
        servers: [Server],
        workspaces: [Workspace],
        deletedServerIDs: [UUID],
        deletedWorkspaceIDs: [UUID],
        isFullFetch: Bool,
        commitFetchedChanges: (@MainActor () async -> Void)?
    ) {
        self.servers = servers
        self.workspaces = workspaces
        self.deletedServerIDs = deletedServerIDs
        self.deletedWorkspaceIDs = deletedWorkspaceIDs
        self.isFullFetch = isFullFetch
        self.commitHandler = commitFetchedChanges
    }

    func commitFetchedChanges() async {
        await commitHandler?()
    }
}

@MainActor
protocol ServerCloudSyncing {
    var isAvailable: Bool { get }

    func fetchChanges(forceFullFetch: Bool) async throws -> CloudKitChanges
    func commitFetchedChanges(_ changes: CloudKitChanges) async
    func saveServer(_ server: Server) async throws
    func saveWorkspace(_ workspace: Workspace) async throws
    func isSchemaError(_ error: Error) -> Bool
}

extension ServerCloudSyncing {
    func commitFetchedChanges(_ changes: CloudKitChanges) async {
        await changes.commitFetchedChanges()
    }
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
