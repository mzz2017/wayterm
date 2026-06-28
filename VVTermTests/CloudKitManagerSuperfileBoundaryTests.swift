import Foundation
import Testing

// Test Context:
// These source-boundary tests protect CloudKitManager superfile control.
// CloudKitManager.swift keeps account state, account-status refresh ownership,
// and record-level sync orchestration, while low-level CloudKit zone, token,
// fetch, save, and error infrastructure lives in a focused Core/Sync extension.
// Product domain codecs live in feature adapters; update only when that
// ownership boundary intentionally changes.
struct CloudKitManagerSuperfileBoundaryTests {
    @Test
    func managerRootDoesNotOwnCloudKitInfrastructureImplementation() throws {
        let root = try sourceRoot()
        let managerSource = try source(
            at: root.appendingPathComponent("VVTerm/Core/Sync/CloudKitManager.swift")
        )
        let infrastructureSource = try source(
            at: root.appendingPathComponent("VVTerm/Core/Sync/CloudKitManager+Infrastructure.swift")
        )

        for functionName in [
            "loadChangeToken",
            "saveChangeToken",
            "fetchAllRecordsFromCloudKit",
            "fetchZoneChanges",
            "saveRecordWithUpsert",
            "saveRecord",
            "ensureCustomZone",
            "withZoneRetry",
            "isZoneNotFound"
        ] {
            #expect(
                !managerSource.contains("func \(functionName)"),
                "CloudKitManager.swift should not own CloudKit infrastructure \(functionName)."
            )
            #expect(
                infrastructureSource.contains("func \(functionName)"),
                "CloudKitManager+Infrastructure.swift should own CloudKit infrastructure \(functionName)."
            )
        }

        #expect(
            managerSource.contains("func fetchRecordChanges("),
            "CloudKitManager.swift should keep record-level change fetch orchestration."
        )
        #expect(
            managerSource.contains("func subscribeToChanges("),
            "CloudKitManager.swift should keep subscription intent API."
        )
    }

    @Test
    func accountStatusRefreshIsTrackedByCloudKitManager() throws {
        let root = try sourceRoot()
        let managerSource = try source(
            at: root.appendingPathComponent("VVTerm/Core/Sync/CloudKitManager.swift")
        )

        // Given CloudKit account status checks are async lifecycle work launched
        // from initialization, settings refresh, and sync-enable paths.
        #expect(managerSource.contains("private var accountStatusRefreshTask"))
        #expect(managerSource.contains("func requestAccountStatusRefresh"))
        #expect(managerSource.contains("clearAccountStatusRefreshTask"))

        // Then initialization must create a manager-owned tracked task instead
        // of an untracked fire-and-forget refresh.
        #expect(
            managerSource.contains("_ = requestAccountStatusRefresh()"),
            "CloudKitManager init should route startup account status through the tracked request owner."
        )
        #expect(
            !managerSource.contains("Task { await checkAccountStatus() }"),
            "CloudKitManager should not launch an untracked startup account status Task."
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
