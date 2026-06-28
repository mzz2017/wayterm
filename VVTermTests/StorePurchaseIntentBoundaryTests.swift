import Foundation
import Testing

// Test Context:
// These tests protect StoreKit purchase and restore entry points. Buying or
// restoring Pro access is lifecycle-critical work: SwiftUI may render buttons
// and observe state, but StoreManager must own request tasks, failure tracking,
// and awaitable completion. Update these tests only when Store purchase/restore
// ownership intentionally moves to another application-layer owner with
// equivalent request tracking and failure propagation.
@Suite
struct StorePurchaseIntentBoundaryTests {
    @Test
    func storeUIUsesApplicationPurchaseAndRestoreRequests() throws {
        // Given SwiftUI files that expose purchase and restore buttons.
        let root = try sourceRoot()
        let sources = try [
            "VVTerm/Features/Store/UI/ProUpgradeSheet.swift",
            "VVTerm/Features/Settings/UI/ProSettingsView.swift"
        ]
            .map { try source(at: root.appendingPathComponent($0)) }
            .joined(separator: "\n")

        // Then those views must send intent to StoreManager instead of owning
        // the purchase/restore task directly.
        #expect(
            !sources.contains("Task { await storeManager.purchase(product) }"),
            "Store purchase buttons should call StoreManager.requestPurchase(of:) instead of starting a SwiftUI-owned task."
        )
        #expect(
            !sources.contains("Task { await storeManager.restorePurchases() }"),
            "Store restore buttons should call StoreManager.requestRestorePurchases() instead of starting a SwiftUI-owned task."
        )
        #expect(
            sources.contains("storeManager.requestPurchase"),
            "Store purchase UI should use the Store application-layer request API."
        )
        #expect(
            sources.contains("storeManager.requestRestorePurchases"),
            "Store restore UI should use the Store application-layer request API."
        )
        #expect(
            !containsStoreRestoreStateAssignment(in: sources),
            "Store restore UI should ask StoreManager to dismiss restore results instead of mutating restore state directly."
        )
        #expect(
            sources.contains("storeManager.dismissRestoreResult()"),
            "Store restore UI should send restore-result dismissal intent through StoreManager."
        )
    }

    private func source(at url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    private func containsStoreRestoreStateAssignment(in source: String) -> Bool {
        let pattern = #"storeManager\.restoreState\s*=(?!=)"#
        return source.range(of: pattern, options: .regularExpression) != nil
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
