import Foundation
import Testing
@testable import Waterm

// Test Context:
// These tests protect ServerManager's response to remote CloudKit deletion
// tombstones. Remote deletes must reuse local teardown and credential cleanup
// without enqueueing another CloudKit delete, and workspace tombstones must
// remove contained servers instead of letting orphan repair resurrect them.
// Fakes avoid CloudKit and Keychain I/O; update these tests only when the
// remote deletion ownership contract intentionally changes.
@Suite(.serialized)
@MainActor
struct ServerManagerRemoteDeletionSyncTests {
    @Test
    func remoteServerTombstoneRunsLocalDeletionCleanupBeforeRemovingMetadata() async throws {
        let previousSyncSetting = enableSyncForTest()
        defer { restoreSyncSetting(previousSyncSetting) }

        // Given a local server exists when CloudKit reports a remote server
        // tombstone for the same ID.
        let workspace = Workspace(id: UUID(), name: "Main", order: 0)
        let server = Server(
            id: UUID(),
            workspaceId: workspace.id,
            name: "Tencent",
            host: "remote-server-delete.example.com",
            username: "root"
        )
        let cloudKit = RemoteDeletionCloudSyncService(changes: CloudKitChanges(
            servers: [],
            workspaces: [],
            deletedServerIDs: [server.id],
            deletedWorkspaceIDs: [],
            isFullFetch: false,
            commitFetchedChanges: nil
        ))
        let probe = RemoteDeletionOrderProbe()
        let managerHolder = RemoteDeletionManagerHolder()
        let syncCoordinator = RemoteDeletionPendingCloudSyncCoordinator()
        let manager = ServerManager.makeForTesting(
            servers: [server],
            workspaces: [workspace],
            deletionTeardown: { server in
                #expect(
                    managerHolder.manager?.servers.contains { $0.id == server.id } == true,
                    "Remote server tombstone cleanup must run before local metadata removal."
                )
                await probe.record("teardown:\(server.id.uuidString)")
            },
            deleteCredentials: { serverId in
                await probe.record("credentials:\(serverId.uuidString)")
            },
            cloudKit: cloudKit,
            syncCoordinator: syncCoordinator
        )
        managerHolder.manager = manager

        // When the incremental CloudKit load applies the remote tombstone.
        await manager.loadData()

        // Then local teardown and credential cleanup run before metadata is
        // removed, matching the user-initiated delete lifecycle contract.
        let events = await probe.events()
        #expect(
            events == [
                "teardown:\(server.id.uuidString)",
                "credentials:\(server.id.uuidString)"
            ],
            "Remote server tombstones must not bypass local teardown and credential cleanup."
        )
        #expect(!manager.servers.contains { $0.id == server.id })
        #expect(
            syncCoordinator.enqueuedServerDeleteIDs.isEmpty,
            "Remote tombstones should not enqueue duplicate CloudKit delete mutations."
        )
    }

    @Test
    func remoteWorkspaceTombstoneDeletesContainedServersThroughLocalCleanup() async throws {
        let previousSyncSetting = enableSyncForTest()
        defer { restoreSyncSetting(previousSyncSetting) }

        // Given a local workspace with child servers exists when CloudKit
        // reports a remote workspace tombstone.
        let workspace = Workspace(id: UUID(), name: "Main", order: 0)
        let firstServer = Server(
            id: UUID(),
            workspaceId: workspace.id,
            name: "Tencent 1",
            host: "remote-workspace-delete-1.example.com",
            username: "root"
        )
        let secondServer = Server(
            id: UUID(),
            workspaceId: workspace.id,
            name: "Tencent 2",
            host: "remote-workspace-delete-2.example.com",
            username: "root"
        )
        let cloudKit = RemoteDeletionCloudSyncService(changes: CloudKitChanges(
            servers: [],
            workspaces: [],
            deletedServerIDs: [],
            deletedWorkspaceIDs: [workspace.id],
            isFullFetch: false,
            commitFetchedChanges: nil
        ))
        let probe = RemoteDeletionOrderProbe()
        let managerHolder = RemoteDeletionManagerHolder()
        let syncCoordinator = RemoteDeletionPendingCloudSyncCoordinator()
        let manager = ServerManager.makeForTesting(
            servers: [firstServer, secondServer],
            workspaces: [workspace],
            deletionTeardown: { server in
                #expect(
                    managerHolder.manager?.workspaces.contains { $0.id == workspace.id } == true,
                    "Remote workspace tombstone cleanup must keep workspace metadata until child server cleanup completes."
                )
                await probe.record("teardown:\(server.id.uuidString)")
            },
            deleteCredentials: { serverId in
                await probe.record("credentials:\(serverId.uuidString)")
            },
            cloudKit: cloudKit,
            syncCoordinator: syncCoordinator
        )
        managerHolder.manager = manager

        // When the incremental CloudKit load applies the remote workspace
        // tombstone.
        await manager.loadData()

        // Then every child server is cleaned up locally and removed instead of
        // being repaired as an orphan under another workspace.
        let events = await probe.events()
        #expect(
            events == [
                "teardown:\(firstServer.id.uuidString)",
                "credentials:\(firstServer.id.uuidString)",
                "teardown:\(secondServer.id.uuidString)",
                "credentials:\(secondServer.id.uuidString)"
            ],
            "Remote workspace tombstones must delete contained servers through the local cleanup path."
        )
        #expect(!manager.workspaces.contains { $0.id == workspace.id })
        #expect(manager.servers.isEmpty)
        #expect(
            syncCoordinator.enqueuedWorkspaceDeleteIDs.isEmpty &&
                syncCoordinator.enqueuedServerDeleteIDs.isEmpty,
            "Remote workspace tombstones should not enqueue duplicate CloudKit delete mutations."
        )
    }

    @Test
    func remoteDeletionCommitsFetchedChangesAfterLocalApplySucceeds() async throws {
        let previousSyncSetting = enableSyncForTest()
        defer { restoreSyncSetting(previousSyncSetting) }

        let workspace = Workspace(id: UUID(), name: "Main", order: 0)
        let server = Server(
            id: UUID(),
            workspaceId: workspace.id,
            name: "Tencent",
            host: "remote-server-ack.example.com",
            username: "root"
        )
        let cloudKit = RemoteDeletionCloudSyncService(changes: CloudKitChanges(
            servers: [],
            workspaces: [],
            deletedServerIDs: [server.id],
            deletedWorkspaceIDs: [],
            isFullFetch: false,
            commitFetchedChanges: nil
        ))
        let manager = ServerManager.makeForTesting(
            servers: [server],
            workspaces: [workspace],
            cloudKit: cloudKit,
            syncCoordinator: RemoteDeletionPendingCloudSyncCoordinator()
        )

        // When a fetched remote tombstone is applied successfully.
        await manager.loadData()

        // Then the CloudKit change token may be committed only after local
        // apply finishes, so future fetches can safely advance past it.
        #expect(
            cloudKit.commitCount == 1,
            "Fetched CloudKit changes should be acknowledged after successful local apply, not during fetch."
        )
    }

    @Test
    func remoteDeletionDoesNotCommitFetchedChangesWhenLocalApplyFails() async throws {
        let previousSyncSetting = enableSyncForTest()
        defer { restoreSyncSetting(previousSyncSetting) }

        let workspace = Workspace(id: UUID(), name: "Main", order: 0)
        let server = Server(
            id: UUID(),
            workspaceId: workspace.id,
            name: "Tencent",
            host: "remote-server-ack-failure.example.com",
            username: "root"
        )
        let cloudKit = RemoteDeletionCloudSyncService(changes: CloudKitChanges(
            servers: [],
            workspaces: [],
            deletedServerIDs: [server.id],
            deletedWorkspaceIDs: [],
            isFullFetch: false,
            commitFetchedChanges: nil
        ))
        let manager = ServerManager.makeForTesting(
            servers: [server],
            workspaces: [workspace],
            deleteCredentials: { _ in
                throw RemoteDeletionSyncTestError.localApplyFailed
            },
            cloudKit: cloudKit,
            syncCoordinator: RemoteDeletionPendingCloudSyncCoordinator()
        )

        // When local cleanup fails while applying the fetched tombstone.
        await manager.loadData()

        // Then the token must remain uncommitted so a later fetch can replay
        // the same remote deletion.
        #expect(
            cloudKit.commitCount == 0,
            "Fetched CloudKit changes must not be acknowledged if local apply fails."
        )
        #expect(manager.servers.contains { $0.id == server.id })
    }
}

private enum RemoteDeletionSyncTestError: Error {
    case localApplyFailed
}

private func enableSyncForTest() -> Any? {
    let previousSyncSetting = UserDefaults.standard.object(forKey: SyncSettings.enabledKey)
    UserDefaults.standard.set(true, forKey: SyncSettings.enabledKey)
    return previousSyncSetting
}

private func restoreSyncSetting(_ previousSyncSetting: Any?) {
    if let previousSyncSetting {
        UserDefaults.standard.set(previousSyncSetting, forKey: SyncSettings.enabledKey)
    } else {
        UserDefaults.standard.removeObject(forKey: SyncSettings.enabledKey)
    }
}

@MainActor
private final class RemoteDeletionManagerHolder: @unchecked Sendable {
    var manager: ServerManager?
}

private actor RemoteDeletionOrderProbe {
    private var recordedEvents: [String] = []

    func record(_ event: String) {
        recordedEvents.append(event)
    }

    func events() -> [String] {
        recordedEvents
    }
}

@MainActor
private final class RemoteDeletionCloudSyncService: ServerCloudSyncing {
    var isAvailable = true
    private let changes: CloudKitChanges
    private(set) var commitCount = 0

    init(changes: CloudKitChanges) {
        self.changes = changes
    }

    func fetchChanges(forceFullFetch: Bool) async throws -> CloudKitChanges {
        changes
    }

    func commitFetchedChanges(_ changes: CloudKitChanges) async {
        commitCount += 1
    }

    func saveServer(_ server: Server) async throws {}

    func saveWorkspace(_ workspace: Workspace) async throws {}

    func isSchemaError(_ error: Error) -> Bool {
        false
    }
}

@MainActor
private final class RemoteDeletionPendingCloudSyncCoordinator: ServerPendingCloudSyncCoordinating {
    private(set) var enqueuedServerDeleteIDs: [UUID] = []
    private(set) var enqueuedWorkspaceDeleteIDs: [UUID] = []

    func snapshot() -> [PendingCloudKitMutation] {
        []
    }

    func clearPendingMutations(for entities: Set<PendingCloudKitEntity>) {}

    func removePendingMutation(_ mutationID: UUID) {}

    func enqueueServerUpsert(_ server: Server) {}

    func enqueueServerDelete(_ server: Server) {
        enqueuedServerDeleteIDs.append(server.id)
    }

    func enqueueWorkspaceUpsert(_ workspace: Workspace) {}

    func enqueueWorkspaceDelete(_ workspace: Workspace) {
        enqueuedWorkspaceDeleteIDs.append(workspace.id)
    }

    func drainPendingMutations() async {}
}
