import Foundation
import Testing

// Test Context:
// These source-boundary tests protect Servers Application superfile control.
// ServerManager owns app-facing server/workspace orchestration; persistence,
// sync, credential, and deletion lifecycle responsibilities should live in
// dedicated Application files so future server-management changes remain
// localized. Update only when those ownership boundaries intentionally move.
@Suite(.serialized)
struct ServerManagerSuperfileBoundaryTests {
    @Test
    func localPersistenceAndBootstrapLiveOutsideServerManagerFile() throws {
        let root = try sourceRoot()
        let managerSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/Servers/Application/ServerManager.swift")
        )
        let persistenceSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/Servers/Application/ServerManager+Persistence.swift")
        )

        // Given local server/workspace persistence and bootstrap workspace
        // reconciliation are durable state responsibilities.
        #expect(persistenceSource.contains("extension ServerManager"))
        #expect(persistenceSource.contains("func loadLocalData"))
        #expect(persistenceSource.contains("func saveLocalData"))
        #expect(persistenceSource.contains("func loadStoredServers"))
        #expect(persistenceSource.contains("func storeWorkspaces"))
        #expect(persistenceSource.contains("var pendingBootstrapWorkspaceID"))
        #expect(persistenceSource.contains("func reconcilePendingBootstrapWorkspaceState"))
        #expect(persistenceSource.contains("func resolvePendingBootstrapWorkspaceAgainstAuthoritativeFetch"))
        #expect(persistenceSource.contains("func shouldCreateBootstrapWorkspace"))

        // Then the ServerManager superfile should not own local persistence
        // and bootstrap state orchestration directly.
        #expect(
            !managerSource.containsRegex(#"func\s+loadLocalData\s*\("#),
            "ServerManager.swift should not own local persistence loading."
        )
        #expect(
            !managerSource.containsRegex(#"func\s+saveLocalData\s*\("#),
            "ServerManager.swift should not own local persistence writes."
        )
        #expect(
            !managerSource.containsRegex(#"func\s+loadStoredServers\s*\("#),
            "ServerManager.swift should not own stored server decoding."
        )
        #expect(
            !managerSource.containsRegex(#"func\s+storeWorkspaces\s*\("#),
            "ServerManager.swift should not own stored workspace encoding."
        )
        #expect(
            !managerSource.containsRegex(#"var\s+pendingBootstrapWorkspaceID\s*:"#),
            "ServerManager.swift should not own persisted bootstrap workspace identity."
        )
        #expect(
            !managerSource.containsRegex(#"func\s+reconcilePendingBootstrapWorkspaceState\s*\("#),
            "ServerManager.swift should not own bootstrap workspace reconciliation."
        )
        #expect(
            !managerSource.containsRegex(#"func\s+resolvePendingBootstrapWorkspaceAgainstAuthoritativeFetch\s*\("#),
            "ServerManager.swift should not own authoritative bootstrap promotion."
        )
        #expect(
            !managerSource.containsRegex(#"func\s+shouldCreateBootstrapWorkspace\s*\("#),
            "ServerManager.swift should not own bootstrap creation policy."
        )
    }

    @Test
    func cloudKitSyncAndStartupLoadingLiveOutsideServerManagerFile() throws {
        let root = try sourceRoot()
        let managerSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/Servers/Application/ServerManager.swift")
        )
        let syncSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/Servers/Application/ServerManager+Sync.swift")
        )
        let syncStateServiceSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/Servers/Application/ServerSyncStateService.swift")
        )

        // Given CloudKit sync, startup loading, and CloudKit merge/backfill are
        // durable application orchestration responsibilities, while value-only
        // sync-state policy belongs to a service.
        #expect(syncSource.contains("extension ServerManager"))
        #expect(syncSource.contains("func enqueuePendingServerUpsert"))
        #expect(syncSource.contains("func enqueuePendingServerDelete"))
        #expect(syncSource.contains("func enqueuePendingWorkspaceUpsert"))
        #expect(syncSource.contains("func enqueuePendingWorkspaceDelete"))
        #expect(syncSource.contains("func applyPendingSyncOverlay"))
        #expect(syncSource.contains("func reconcilePendingServerAndWorkspaceUpsertsAgainstCloudKit"))
        #expect(syncSource.contains("func drainPendingCloudKitMutations"))
        #expect(syncSource.contains("func persistLocalMutations"))
        #expect(syncSource.contains("func startStartupLoad"))
        #expect(syncSource.contains("func waitForStartupLoadRequest"))
        #expect(syncSource.contains("func loadData"))
        #expect(syncSource.contains("func backfillMissingLocalRecordsIfNeeded"))
        #expect(syncSource.contains("syncStateService.backfillCandidates"))
        #expect(syncSource.contains("func applyCloudKitChanges"))
        #expect(syncSource.contains("syncStateService.fullFetchState"))
        #expect(syncSource.contains("func repairOrphanedServers"))
        #expect(syncSource.contains("syncStateService.orphanRepairPlan"))
        #expect(syncSource.contains("func initializeCloudKitSchema"))
        #expect(syncStateServiceSource.contains("struct ServerSyncStateService"))
        #expect(syncStateServiceSource.contains("func backfillCandidates"))
        #expect(syncStateServiceSource.contains("func fullFetchState"))
        #expect(syncStateServiceSource.contains("func orphanRepairPlan"))
        #expect(syncStateServiceSource.contains("func knownHostRemovalCandidates"))

        // Then the ServerManager superfile should not own sync/load lifecycle
        // orchestration directly.
        #expect(
            !managerSource.containsRegex(#"func\s+enqueuePendingServerUpsert\s*\("#),
            "ServerManager.swift should not own pending server sync upserts."
        )
        #expect(
            !managerSource.containsRegex(#"func\s+enqueuePendingWorkspaceDelete\s*\("#),
            "ServerManager.swift should not own pending workspace sync deletes."
        )
        #expect(
            !managerSource.containsRegex(#"func\s+applyPendingSyncOverlay\s*\("#),
            "ServerManager.swift should not own pending sync overlay application."
        )
        #expect(
            !managerSource.containsRegex(#"func\s+reconcilePendingServerAndWorkspaceUpsertsAgainstCloudKit\s*\("#),
            "ServerManager.swift should not own CloudKit pending sync reconciliation."
        )
        #expect(
            !managerSource.containsRegex(#"func\s+drainPendingCloudKitMutations\s*\("#),
            "ServerManager.swift should not own pending CloudKit mutation draining."
        )
        #expect(
            !managerSource.containsRegex(#"func\s+startStartupLoad\s*\("#),
            "ServerManager.swift should not own startup load request lifecycle."
        )
        #expect(
            !managerSource.containsRegex(#"func\s+loadData\s*\("#),
            "ServerManager.swift should not own CloudKit data loading."
        )
        #expect(
            !managerSource.containsRegex(#"func\s+backfillMissingLocalRecordsIfNeeded\s*\("#),
            "ServerManager.swift should not own CloudKit backfill orchestration."
        )
        #expect(
            !managerSource.containsRegex(#"func\s+applyCloudKitChanges\s*\("#),
            "ServerManager.swift should not own CloudKit merge application."
        )
        #expect(
            !managerSource.containsRegex(#"func\s+repairOrphanedServers\s*\("#),
            "ServerManager.swift should not own sync-time orphan repair."
        )
        #expect(
            !managerSource.containsRegex(#"func\s+initializeCloudKitSchema\s*\("#),
            "ServerManager.swift should not own CloudKit schema initialization."
        )
    }

    @Test
    func requestCoordinationLivesOutsideServerManagerFile() throws {
        let root = try sourceRoot()
        let managerSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/Servers/Application/ServerManager.swift")
        )
        let requestSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/Servers/Application/ServerManager+Requests.swift")
        )

        // Given UI-facing request APIs and their tracked Tasks are lifecycle
        // coordination rather than core server/workspace mutation rules.
        #expect(requestSource.contains("extension ServerManager"))
        #expect(requestSource.contains("func requestServerSave"))
        #expect(requestSource.contains("func requestServerDeletion"))
        #expect(requestSource.contains("func requestWorkspaceSave"))
        #expect(requestSource.contains("func requestWorkspaceDeletion"))
        #expect(requestSource.contains("func requestEnvironmentDeletion"))
        #expect(requestSource.contains("func requestServerMove"))
        #expect(requestSource.contains("func requestEnvironmentSave"))
        #expect(requestSource.contains("func waitForDeletionRequest"))
        #expect(requestSource.contains("func waitForServerSaveRequest"))
        #expect(requestSource.contains("func waitForWorkspaceSaveRequest"))
        #expect(requestSource.contains("func waitForEnvironmentSaveRequest"))
        #expect(requestSource.contains("func waitForServerMoveRequest"))
        #expect(requestSource.contains("func trackDeletionRequest"))
        #expect(requestSource.contains("func trackServerSaveRequest"))
        #expect(requestSource.contains("func trackWorkspaceSaveRequest"))
        #expect(requestSource.contains("func trackEnvironmentSaveRequest"))
        #expect(requestSource.contains("func trackServerMoveRequest"))

        // Then the ServerManager superfile should not own request Task
        // tracking and UI failure coordination directly.
        for functionName in [
            "requestServerSave",
            "requestServerDeletion",
            "requestWorkspaceSave",
            "requestWorkspaceDeletion",
            "requestEnvironmentDeletion",
            "requestServerMove",
            "requestEnvironmentSave",
            "waitForDeletionRequest",
            "waitForServerSaveRequest",
            "waitForWorkspaceSaveRequest",
            "waitForEnvironmentSaveRequest",
            "waitForServerMoveRequest",
            "trackDeletionRequest",
            "trackServerSaveRequest",
            "trackWorkspaceSaveRequest",
            "trackEnvironmentSaveRequest",
            "trackServerMoveRequest"
        ] {
            #expect(
                !managerSource.containsRegex(#"func\s+\#(functionName)\s*\("#),
                "ServerManager.swift should not own \(functionName)."
            )
        }
    }

    @Test
    func credentialAndDeletionDefaultsLiveOutsideServerManagerFile() throws {
        let root = try sourceRoot()
        let managerSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/Servers/Application/ServerManager.swift")
        )
        let credentialSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/Servers/Infrastructure/ServerManager+CredentialLifecycle.swift")
        )

        // Given default Keychain and teardown adapters are credential/deletion
        // lifecycle infrastructure glue, not core server list orchestration.
        #expect(credentialSource.contains("extension ServerManager"))
        #expect(credentialSource.contains("func defaultDeletionTeardown"))
        #expect(credentialSource.contains("func defaultCredentialDeletion"))
        #expect(credentialSource.contains("func defaultCredentialStore"))
        #expect(credentialSource.contains("KeychainManager.shared"))
        #expect(credentialSource.contains("ConnectionSessionManager.shared.disconnectServerAndWait"))
        #expect(credentialSource.contains("TerminalTabManager.shared.disconnectServerAndWait"))

        // Then the ServerManager superfile should not directly own default
        // credential persistence or deletion teardown adapters.
        #expect(
            !managerSource.containsRegex(#"func\s+defaultDeletionTeardown\s*\("#),
            "ServerManager.swift should not own default server deletion teardown."
        )
        #expect(
            !managerSource.containsRegex(#"func\s+defaultCredentialDeletion\s*\("#),
            "ServerManager.swift should not own default credential deletion."
        )
        #expect(
            !managerSource.containsRegex(#"func\s+defaultCredentialStore\s*\("#),
            "ServerManager.swift should not own default credential storage."
        )
        #expect(
            !managerSource.contains("KeychainManager.shared"),
            "ServerManager.swift should not directly depend on KeychainManager."
        )
    }

    @Test
    func deletionMutationLifecycleLivesOutsideServerManagerFile() throws {
        let root = try sourceRoot()
        let managerSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/Servers/Application/ServerManager.swift")
        )
        let deletionSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/Servers/Application/ServerManager+Deletion.swift")
        )

        // Given destructive server/workspace/environment mutations coordinate
        // teardown, credentials, known-host cleanup, local persistence, and sync.
        #expect(deletionSource.contains("extension ServerManager"))
        #expect(deletionSource.contains("func deleteServer"))
        #expect(deletionSource.contains("func deleteWorkspace"))
        #expect(deletionSource.contains("func deleteEnvironment"))
        #expect(deletionSource.contains("deletionTeardown"))
        #expect(deletionSource.contains("deleteCredentials"))
        #expect(deletionSource.contains("removeKnownHosts"))
        #expect(deletionSource.contains("enqueuePendingServerDelete"))
        #expect(deletionSource.contains("enqueuePendingWorkspaceDelete"))

        // Then the ServerManager superfile should not directly own destructive
        // deletion lifecycle implementations.
        #expect(
            !managerSource.containsRegex(#"func\s+deleteServer\s*\("#),
            "ServerManager.swift should not own server deletion lifecycle."
        )
        #expect(
            !managerSource.containsRegex(#"func\s+deleteWorkspace\s*\("#),
            "ServerManager.swift should not own workspace deletion lifecycle."
        )
        #expect(
            !managerSource.containsRegex(#"func\s+deleteEnvironment\s*\("#),
            "ServerManager.swift should not own environment deletion lifecycle."
        )
    }

    @Test
    func queryHelpersLiveOutsideServerManagerFile() throws {
        let root = try sourceRoot()
        let managerSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/Servers/Application/ServerManager.swift")
        )
        let querySource = try source(
            at: root.appendingPathComponent("VVTerm/Features/Servers/Application/ServerManager+Queries.swift")
        )

        // Given read-only filtering/search helpers are presentation query
        // helpers, not core mutation orchestration.
        #expect(querySource.contains("extension ServerManager"))
        #expect(querySource.contains("func servers(in workspace: Workspace"))
        #expect(querySource.contains("func recentServers"))
        #expect(querySource.contains("func favoriteServers"))
        #expect(querySource.contains("func searchServers"))
        #expect(querySource.contains("func workspace(withId"))

        for functionName in [
            "servers",
            "recentServers",
            "favoriteServers",
            "searchServers",
            "workspace"
        ] {
            #expect(
                !managerSource.containsRegex(#"func\s+\#(functionName)\s*\("#),
                "ServerManager.swift should not own \(functionName) query helper."
            )
        }
    }

    @Test
    func accessPolicyHelpersLiveOutsideServerManagerFile() throws {
        let root = try sourceRoot()
        let managerSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/Servers/Application/ServerManager.swift")
        )
        let accessSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/Servers/Application/ServerManager+AccessPolicy.swift")
        )

        // Given Pro/free-tier access helpers delegate to ServerAccessPolicy and
        // should not inflate the composition root.
        #expect(accessSource.contains("extension ServerManager"))
        #expect(accessSource.contains("var canAddServer"))
        #expect(accessSource.contains("var canAddWorkspace"))
        #expect(accessSource.contains("var canCreateCustomEnvironment"))
        #expect(accessSource.contains("var unlockedServerIds"))
        #expect(accessSource.contains("var unlockedWorkspaceIds"))
        #expect(accessSource.contains("func isServerLocked"))
        #expect(accessSource.contains("func isWorkspaceLocked"))
        #expect(accessSource.contains("var lockedServersCount"))
        #expect(accessSource.contains("var lockedWorkspacesCount"))
        #expect(accessSource.contains("var hasLockedItems"))
        #expect(accessSource.contains("isProProvider()"))
        #expect(
            !accessSource.contains("StoreManager.shared.isPro"),
            "ServerManager access policy should receive entitlement state through the manager boundary."
        )

        for propertyName in [
            "canAddServer",
            "canAddWorkspace",
            "canCreateCustomEnvironment",
            "unlockedServerIds",
            "unlockedWorkspaceIds",
            "lockedServersCount",
            "lockedWorkspacesCount",
            "hasLockedItems"
        ] {
            #expect(
                !managerSource.containsRegex(#"var\s+\#(propertyName)\s*:"#),
                "ServerManager.swift should not own \(propertyName) access-policy helper."
            )
        }

        for functionName in [
            "isServerLocked",
            "isWorkspaceLocked"
        ] {
            #expect(
                !managerSource.containsRegex(#"func\s+\#(functionName)\s*\("#),
                "ServerManager.swift should not own \(functionName) access-policy helper."
            )
        }
    }

    @Test
    func moveAndEnvironmentHelpersLiveOutsideServerManagerFile() throws {
        let root = try sourceRoot()
        let managerSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/Servers/Application/ServerManager.swift")
        )
        let moveSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/Servers/Application/ServerManager+Move.swift")
        )
        let environmentSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/Servers/Application/ServerManager+Environment.swift")
        )

        // Given move and environment mutation helpers are secondary workflows
        // around server/workspace state.
        #expect(moveSource.contains("extension ServerManager"))
        #expect(moveSource.contains("func assignmentWorkspaces"))
        #expect(moveSource.contains("func moveDestinations"))
        #expect(moveSource.contains("func resolvedEnvironment"))
        #expect(moveSource.contains("func moveRequiresEnvironmentFallback"))
        #expect(moveSource.contains("func canAssignServer"))
        #expect(moveSource.contains("func moveServer"))
        #expect(moveSource.contains("func moveRestriction"))
        #expect(moveSource.contains("func moveDestinationIDs"))
        #expect(moveSource.contains("func updateWorkspaceSelectionMetadataAfterMove"))
        #expect(moveSource.contains("isProProvider()"))
        #expect(
            !moveSource.contains("StoreManager.shared.isPro"),
            "ServerManager move policy should receive entitlement state through the manager boundary."
        )
        #expect(environmentSource.contains("extension ServerManager"))
        #expect(environmentSource.contains("func createCustomEnvironment"))
        #expect(environmentSource.contains("func updateEnvironment"))
        #expect(environmentSource.contains("func handleAppLanguageChange"))

        for functionName in [
            "assignmentWorkspaces",
            "moveDestinations",
            "resolvedEnvironment",
            "moveRequiresEnvironmentFallback",
            "canAssignServer",
            "moveServer",
            "moveRestriction",
            "moveDestinationIDs",
            "updateWorkspaceSelectionMetadataAfterMove",
            "createCustomEnvironment",
            "updateEnvironment",
            "handleAppLanguageChange"
        ] {
            #expect(
                !managerSource.containsRegex(#"func\s+\#(functionName)\s*\("#),
                "ServerManager.swift should not own \(functionName) workflow helper."
            )
        }
    }

    private func source(at url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    private func sourceRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.lastPathComponent != "VVTermTests" {
            let next = url.deletingLastPathComponent()
            if next.path == url.path {
                throw SourceRootError.notFound
            }
            url = next
        }
        return url.deletingLastPathComponent()
    }

    private enum SourceRootError: Error {
        case notFound
    }
}

private extension String {
    func containsRegex(_ pattern: String) -> Bool {
        range(of: pattern, options: .regularExpression) != nil
    }
}
