import XCTest
@testable import VVTerm

// Test Context:
// These tests protect terminal accessory validation rules and diagnostics. They
// use pure profile fixtures and no UI presentation; update only when validation
// semantics intentionally change.

final class TerminalAccessoryValidationTests: XCTestCase {
    func testEmptyTitleErrorMessage() {
        XCTAssertEqual(
            TerminalAccessoryValidationError.emptyTitle.errorDescription,
            "Action title cannot be empty."
        )
    }

    func testCustomActionLimitErrorUsesProfileLimit() {
        XCTAssertEqual(
            TerminalAccessoryValidationError.customActionLimitReached.errorDescription,
            "You can create up to \(TerminalAccessoryProfile.maxCustomActions) custom actions."
        )
    }
}
