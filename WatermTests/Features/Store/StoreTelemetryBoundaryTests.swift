import Foundation
import Testing

// Test Context:
// These tests protect Store purchase and paywall telemetry ownership. Store UI
// may send purchase/review intent, and StoreManager owns StoreKit lifecycle, but
// analytics and engagement side effects must be injected through StoreTelemetry
// so tests and future services can replace live trackers at the feature boundary.
// Update these tests only when Store telemetry ownership intentionally moves to
// another application-layer service.

@Suite
struct StoreTelemetryBoundaryTests {
    @Test
    func storeManagerUsesInjectedTelemetryInsteadOfTrackerSingletons() throws {
        // Given the Store application owner source.
        let root = try sourceRoot()
        let source = try source(
            at: root.appendingPathComponent("Waterm/Features/Store/Application/StoreManager.swift")
        )

        // Then StoreManager should own purchase lifecycle and delegate analytics
        // through an injected feature service, not direct global tracker calls.
        #expect(
            !source.contains("AnalyticsTracker.shared"),
            "StoreManager should use injected StoreTelemetry instead of AnalyticsTracker.shared."
        )
        #expect(
            !source.contains("EngagementTracker.shared"),
            "StoreManager should use injected StoreTelemetry instead of EngagementTracker.shared."
        )
        #expect(
            source.contains("private let telemetry: any StoreTelemetry"),
            "StoreManager should keep telemetry as an injected application-layer dependency."
        )
    }

    @Test
    func proUpgradeSheetSendsReviewIntentThroughStoreManager() throws {
        // Given the Store upgrade UI source.
        let root = try sourceRoot()
        let source = try source(
            at: root.appendingPathComponent("Waterm/Features/Store/UI/ProUpgradeSheet.swift")
        )

        // Then purchase-success UI should send review intent to StoreManager
        // instead of directly resolving the engagement singleton.
        #expect(
            !source.contains("EngagementTracker.shared"),
            "ProUpgradeSheet should not directly resolve EngagementTracker."
        )
        #expect(
            source.contains("storeManager.requestReviewAfterPurchase()"),
            "ProUpgradeSheet should route post-purchase review intent through StoreManager."
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
