import Foundation
import Testing

// Test Context:
// These source-boundary tests protect CloudKitManager superfile control.
// CloudKitManager.swift keeps account state and product record sync APIs, while
// low-level CloudKit zone, token, fetch, save, and error infrastructure lives in
// a focused Core/Sync extension. Update only when that ownership boundary
// intentionally changes.
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
            managerSource.contains("func saveServer("),
            "CloudKitManager.swift should keep product-facing server sync APIs."
        )
        #expect(
            managerSource.contains("func fetchChanges("),
            "CloudKitManager.swift should keep product-facing change fetch orchestration."
        )
        #expect(
            managerSource.contains("func subscribeToChanges("),
            "CloudKitManager.swift should keep subscription intent API."
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
