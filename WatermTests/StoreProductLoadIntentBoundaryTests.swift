import Foundation
import Testing

// Test Context:
// These tests protect the Store paywall product-loading boundary. Product
// loading affects purchase choices and can touch StoreKit/network work, so
// SwiftUI may present loading state and choose a selected plan, but StoreManager
// must own request task lifetime, duplicate-load coalescing, and awaitable
// completion. Update these tests only when paywall product loading intentionally
// moves to another application-layer owner with equivalent request tracking.
@Suite
struct StoreProductLoadIntentBoundaryTests {
    @Test
    func paywallUsesApplicationProductLoadRequests() throws {
        // Given the SwiftUI paywall sheet that displays StoreKit products.
        let root = try sourceRoot()
        let source = try source(at: root.appendingPathComponent("Waterm/Features/Store/UI/ProUpgradeSheet.swift"))

        // Then the view must send product-load intent to StoreManager instead
        // of awaiting StoreKit product loading directly from SwiftUI lifecycle.
        #expect(
            !source.contains("loadProducts("),
            "ProUpgradeSheet should call StoreManager.requestProductLoad instead of directly invoking loadProducts from SwiftUI."
        )
        #expect(
            source.contains("storeManager.requestProductLoad"),
            "ProUpgradeSheet should use the Store application-layer product-load request API."
        )
    }

    private func source(at url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    private func sourceRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.lastPathComponent != "WatermTests" {
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
