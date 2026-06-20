import XCTest
@testable import VVTerm

final class FreeTierLimitsTests: XCTestCase {
    func testFreeTierAllowsTwoConnections() {
        XCTAssertEqual(FreeTierLimits.maxTabs, 2)
    }

    func testFreeTierKeepsOneFileTab() {
        XCTAssertEqual(FreeTierLimits.maxFileTabs, 1)
    }
}
