import XCTest
@testable import VVTerm

// Test Context:
// These tests protect Store free-tier limit rules for workspaces, servers, and
// terminal tabs. Fakes use in-memory managers and entitlement state; update only
// when product limits or entitlement semantics intentionally change.

final class FreeTierLimitsTests: XCTestCase {
    func testFreeTierAllowsTwoConnections() {
        XCTAssertEqual(FreeTierLimits.maxTabs, 2)
    }

    func testFreeTierKeepsOneFileTab() {
        XCTAssertEqual(FreeTierLimits.maxFileTabs, 1)
    }
}
