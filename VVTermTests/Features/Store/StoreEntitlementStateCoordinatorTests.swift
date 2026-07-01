import Testing
@testable import VVTerm

// Test Context:
// These tests protect the Store entitlement state publication owner. Fakes avoid
// StoreKit transactions; update only when stale entitlement suppression,
// review-mode overlay, or lifetime-access publishing intentionally moves to
// another Store application owner.
@Suite
struct StoreEntitlementStateCoordinatorTests {
    @Test
    func newerEntitlementSnapshotPublishesAccessState() {
        var coordinator = StoreEntitlementStateCoordinator()

        // Given a StoreKit entitlement refresh starts and produces an active
        // lifetime snapshot.
        let token = coordinator.beginRefresh()
        let state = coordinator.publishIfCurrent(
            token,
            snapshot: StoreEntitlementSnapshot(
                hasAccess: true,
                hasLifetime: true,
                status: nil
            ),
            isReviewModeEnabled: false
        )

        // Then the coordinator publishes the state StoreManager should apply
        // to feature gates and telemetry.
        #expect(state?.isPro == true)
        #expect(state?.isLifetime == true)
        #expect(state?.status == nil)
        #expect(state?.hasStoreAccess == true)
    }

    @Test
    func staleEntitlementSnapshotCannotRollbackNewerAccessState() {
        var coordinator = StoreEntitlementStateCoordinator()
        let staleToken = coordinator.beginRefresh()
        let currentToken = coordinator.beginRefresh()

        // Given a newer refresh has already published active access.
        let currentState = coordinator.publishIfCurrent(
            currentToken,
            snapshot: StoreEntitlementSnapshot(
                hasAccess: true,
                hasLifetime: true,
                status: nil
            ),
            isReviewModeEnabled: false
        )

        // When an older refresh finishes late with a stale free snapshot.
        let staleState = coordinator.publishIfCurrent(
            staleToken,
            snapshot: StoreEntitlementSnapshot(
                hasAccess: false,
                hasLifetime: false,
                status: nil
            ),
            isReviewModeEnabled: false
        )

        // Then only the current snapshot is publishable.
        #expect(currentState?.isPro == true)
        #expect(staleState == nil)
    }

    @Test
    func reviewModeOverlayGrantsProWithoutClaimingLifetimePurchase() {
        var coordinator = StoreEntitlementStateCoordinator()

        // Given review mode is active while StoreKit has no paid entitlement.
        let token = coordinator.beginRefresh()
        let state = coordinator.publishIfCurrent(
            token,
            snapshot: StoreEntitlementSnapshot(
                hasAccess: false,
                hasLifetime: false,
                status: nil
            ),
            isReviewModeEnabled: true
        )

        // Then feature gates unlock Pro for review, but lifetime ownership
        // remains tied to real StoreKit state.
        #expect(state?.isPro == true)
        #expect(state?.isLifetime == false)
        #expect(state?.hasStoreAccess == false)
    }
}
