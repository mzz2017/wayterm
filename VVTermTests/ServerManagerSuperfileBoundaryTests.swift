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

        // Given CloudKit sync, startup loading, and CloudKit merge/backfill are
        // durable application orchestration responsibilities.
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
        #expect(syncSource.contains("func backfillCandidates"))
        #expect(syncSource.contains("func applyCloudKitChanges"))
        #expect(syncSource.contains("func repairOrphanedServers"))
        #expect(syncSource.contains("func initializeCloudKitSchema"))

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
