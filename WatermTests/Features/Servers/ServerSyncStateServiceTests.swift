import Foundation
import Testing
@testable import Waterm

// Test Context:
// These tests protect Servers sync-state policy without CloudKit, Keychain, or
// KnownHosts I/O. ServerManager should orchestrate transport, persistence, and
// logging while ServerSyncStateService owns value-only backfill, merge, orphan
// repair, and known-host cleanup rules. Update only when sync-state semantics
// intentionally change.
@Suite
struct ServerSyncStateServiceTests {
    private let service = ServerSyncStateService()

    @Test
    func backfillCandidatesIgnoreTransientBootstrapWorkspace() {
        let bootstrapWorkspace = Workspace(
            id: UUID(),
            name: "My Servers",
            order: 0
        )
        let remoteWorkspace = Workspace(id: UUID(), name: "Remote", order: 1)

        let bootstrapServer = Server(
            id: UUID(),
            workspaceId: bootstrapWorkspace.id,
            name: "Placeholder",
            host: "bootstrap.example.com",
            username: "root"
        )
        let remoteServer = Server(
            id: UUID(),
            workspaceId: remoteWorkspace.id,
            name: "Needs Upload",
            host: "remote.example.com",
            username: "root"
        )

        // Given a transient bootstrap workspace that should not be uploaded to
        // CloudKit while another local workspace is already authoritative.
        let candidates = service.backfillCandidates(
            localWorkspaces: [bootstrapWorkspace, remoteWorkspace],
            localServers: [bootstrapServer, remoteServer],
            cloudWorkspaceIDs: [remoteWorkspace.id],
            cloudServerIDs: [],
            transientBootstrapWorkspaceID: bootstrapWorkspace.id
        )

        // Then only the non-transient server remains eligible for backfill.
        #expect(candidates.workspaces.isEmpty)
        #expect(candidates.servers.map(\.id) == [remoteServer.id])
    }

    @Test
    func backfillCandidatesIncludeBootstrapWorkspaceAfterPromotion() {
        let bootstrapWorkspace = Workspace(
            id: UUID(),
            name: "My Servers",
            order: 0
        )

        // Given the bootstrap workspace has been promoted to durable local
        // state and no longer has a transient identity marker.
        let candidates = service.backfillCandidates(
            localWorkspaces: [bootstrapWorkspace],
            localServers: [],
            cloudWorkspaceIDs: [],
            cloudServerIDs: [],
            transientBootstrapWorkspaceID: nil
        )

        // Then it must be uploaded during CloudKit backfill.
        #expect(candidates.workspaces.map(\.id) == [bootstrapWorkspace.id])
        #expect(candidates.servers.isEmpty)
    }

    @Test
    func fullFetchStateDeduplicatesByIDAndSortsForStableLocalState() {
        let workspaceID = UUID()
        let oldWorkspace = Workspace(id: workspaceID, name: "Old", order: 9)
        let newWorkspace = Workspace(id: workspaceID, name: "New", order: 2)
        let firstWorkspace = Workspace(id: UUID(), name: "First", order: 1)
        let oldServer = Server(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            workspaceId: workspaceID,
            name: "zeta",
            host: "old.example.com",
            username: "root"
        )
        let replacementServer = Server(
            id: oldServer.id,
            workspaceId: workspaceID,
            name: "alpha",
            host: "new.example.com",
            username: "root"
        )

        // Given CloudKit returns duplicate IDs and out-of-order records during
        // a full fetch.
        let state = service.fullFetchState(
            workspaces: [oldWorkspace, firstWorkspace, newWorkspace],
            servers: [oldServer, replacementServer]
        )

        // Then last-by-ID records win and state is sorted deterministically.
        #expect(state.workspaces.map(\.name) == ["First", "New"])
        #expect(state.servers.map(\.host) == ["new.example.com"])
    }

    @Test
    func orphanRepairCreatesFallbackWorkspaceWhenServersExistWithoutAnyWorkspace() {
        let orphanedServer = Server(
            id: UUID(),
            workspaceId: UUID(),
            name: "Lost Server",
            host: "lost.example.com",
            username: "root"
        )
        let fallbackWorkspace = Workspace(id: UUID(), name: "My Servers", order: 0)

        // Given local server metadata references no existing workspace.
        let repairWorkspace = service.workspaceForOrphanRepair(
            existingWorkspaces: [],
            servers: [orphanedServer],
            fallbackWorkspace: fallbackWorkspace
        )

        // Then the sync policy chooses the fallback workspace for recovery.
        #expect(repairWorkspace?.id == fallbackWorkspace.id)
    }

    @Test
    func orphanRepairPlanReassignsServersAndPreservesRepairTimestamp() {
        let missingWorkspaceID = UUID()
        let workspace = Workspace(id: UUID(), name: "Main", order: 0)
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let orphanedServer = Server(
            id: UUID(),
            workspaceId: missingWorkspaceID,
            name: "Lost Server",
            host: "lost.example.com",
            username: "root",
            updatedAt: Date(timeIntervalSince1970: 100)
        )

        // Given an existing workspace can absorb orphaned server metadata.
        let plan = service.orphanRepairPlan(
            workspaces: [workspace],
            servers: [orphanedServer],
            fallbackWorkspace: Workspace(id: UUID(), name: "Fallback", order: 1),
            updatedAt: timestamp
        )

        // Then the repair plan is value-only and tells ServerManager exactly
        // which repaired records need syncing.
        #expect(plan.createdWorkspace == nil)
        #expect(plan.repairs.map(\.original.workspaceId) == [missingWorkspaceID])
        #expect(plan.repairs.map(\.repaired.workspaceId) == [workspace.id])
        #expect(plan.servers.map(\.workspaceId) == [workspace.id])
        #expect(plan.servers.map(\.updatedAt) == [timestamp])
    }

    @Test
    func orphanRepairDoesNothingWhenAllServersAlreadyHaveValidWorkspaces() {
        let workspace = Workspace(id: UUID(), name: "Main", order: 0)
        let validServer = Server(
            id: UUID(),
            workspaceId: workspace.id,
            name: "Healthy",
            host: "healthy.example.com",
            username: "root"
        )
        let fallbackWorkspace = Workspace(id: UUID(), name: "Fallback", order: 1)

        // Given every server already references a known workspace.
        let repairWorkspace = service.workspaceForOrphanRepair(
            existingWorkspaces: [workspace],
            servers: [validServer],
            fallbackWorkspace: fallbackWorkspace
        )

        // Then no repair workspace is needed.
        #expect(repairWorkspace == nil)
    }

    @Test
    func knownHostRemovalCandidatesUsePostDeleteServerState() {
        let workspaceID = UUID()
        let deletedSharedHost = Server(
            id: UUID(),
            workspaceId: workspaceID,
            name: "Deleted Shared",
            host: "shared.example.com",
            username: "root"
        )
        let remainingSharedHost = Server(
            id: UUID(),
            workspaceId: workspaceID,
            name: "Remaining Shared",
            host: "shared.example.com",
            username: "root"
        )
        let deletedUniqueHost = Server(
            id: UUID(),
            workspaceId: workspaceID,
            name: "Deleted Unique",
            host: "unique.example.com",
            username: "root"
        )

        // Given only one deleted server host is unused after deletion.
        let candidates = service.knownHostRemovalCandidates(
            removedServers: [deletedSharedHost, deletedUniqueHost],
            remainingServers: [remainingSharedHost]
        )

        // Then shared host trust is preserved for the remaining server.
        #expect(
            candidates == [
                ServerKnownHostRemovalCandidate(host: "unique.example.com", port: 22)
            ],
            "Known-host cleanup must preserve hosts still referenced by post-delete server state."
        )
    }
}
