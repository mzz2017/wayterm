import XCTest
import StoreKit
@testable import Waterm

// Test Context:
// These tests protect Store state and entitlement transitions used by Pro/free
// feature gates. Fakes avoid StoreKit network calls; update only when entitlement
// or purchase-state semantics intentionally change.

final class StoreStateTests: XCTestCase {
    func testPurchaseStateEqualityMatchesAssociatedMessage() {
        XCTAssertEqual(PurchaseState.failed("A"), PurchaseState.failed("A"))
        XCTAssertNotEqual(PurchaseState.failed("A"), PurchaseState.failed("B"))
    }

    func testRestoreStateEqualityMatchesAssociatedValues() {
        XCTAssertEqual(RestoreState.restored(hasAccess: true), RestoreState.restored(hasAccess: true))
        XCTAssertNotEqual(RestoreState.restored(hasAccess: true), RestoreState.restored(hasAccess: false))
    }

    func testStoreErrorFormatsPurchaseFailureMessage() {
        let error = StoreError.purchaseFailed("network")

        XCTAssertEqual(error.errorDescription, "Purchase failed: network")
    }

    func testSubscriptionRenewalStateAccessPolicyOnlyEntitlesActiveServiceStates() {
        XCTAssertTrue(StoreSubscriptionAccessPolicy.grantsAccess(for: .subscribed))
        XCTAssertTrue(StoreSubscriptionAccessPolicy.grantsAccess(for: .inGracePeriod))
        XCTAssertFalse(
            StoreSubscriptionAccessPolicy.grantsAccess(for: .inBillingRetryPeriod),
            "Billing retry without another current entitlement must not unlock Pro access."
        )
        XCTAssertFalse(StoreSubscriptionAccessPolicy.grantsAccess(for: .expired))
        XCTAssertFalse(StoreSubscriptionAccessPolicy.grantsAccess(for: .revoked))
    }
}
