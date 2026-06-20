import XCTest
@testable import VVTerm

// Test Context:
// These tests protect biometric-auth domain models and display decisions. They
// use pure model values and no LocalAuthentication calls; update only when
// biometric auth semantics intentionally change.

final class BiometricAuthModelsTests: XCTestCase {
    func testCancelledErrorHasNoDescriptionAndIsMarkedCancellation() {
        let error = BiometricAuthError.cancelled

        XCTAssertNil(error.errorDescription)
        XCTAssertTrue(error.isCancellation)
    }

    func testUnavailableErrorPreservesMessage() {
        let error = BiometricAuthError.unavailable("Unavailable")

        XCTAssertEqual(error.errorDescription, "Unavailable")
        XCTAssertFalse(error.isCancellation)
    }
}
