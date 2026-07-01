import Testing
@testable import VVTerm

// Test Context:
// These tests protect the Store entitlement refresh generation gate. The gate
// is the small state owner that prevents an older StoreKit entitlement snapshot
// from publishing after a newer refresh has already completed. Update these
// tests only when stale-refresh suppression intentionally moves to another
// Store application owner.
@Suite
struct StoreEntitlementRefreshGenerationGateTests {
    @Test
    func olderRefreshTokenCannotPublishAfterNewerRefreshBegins() {
        var gate = StoreEntitlementRefreshGenerationGate()

        // Given one entitlement refresh starts, then a newer refresh starts
        // before the older snapshot can publish.
        let olderToken = gate.beginRefresh()
        let newerToken = gate.beginRefresh()

        // Then only the latest token is allowed to publish entitlement state.
        #expect(!gate.isCurrent(olderToken))
        #expect(gate.isCurrent(newerToken))
    }
}
