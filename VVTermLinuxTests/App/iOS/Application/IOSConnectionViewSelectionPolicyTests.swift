import XCTest
@testable import VVTermIOSApplicationLogic

final class IOSConnectionViewSelectionPolicyTests: XCTestCase {
    func testPreferredConnectViewUsesTerminalWhenVisible() {
        let result = IOSConnectionViewSelectionPolicy.preferredConnectViewId(
            isTerminalVisible: true,
            effectiveDefaultViewId: "stats"
        )

        XCTAssertEqual(result, "terminal")
    }

    func testPreferredConnectViewFallsBackToEffectiveDefaultWhenTerminalIsHidden() {
        let result = IOSConnectionViewSelectionPolicy.preferredConnectViewId(
            isTerminalVisible: false,
            effectiveDefaultViewId: "files"
        )

        XCTAssertEqual(result, "files")
    }

    func testStoredViewKeepsVisibleRequestedView() {
        let result = IOSConnectionViewSelectionPolicy.storedViewId(
            requestedViewId: "files",
            isRequestedViewVisible: true,
            effectiveDefaultViewId: "stats"
        )

        XCTAssertEqual(result, "files")
    }

    func testStoredViewFallsBackWhenRequestedViewIsHidden() {
        let result = IOSConnectionViewSelectionPolicy.storedViewId(
            requestedViewId: "files",
            isRequestedViewVisible: false,
            effectiveDefaultViewId: "terminal"
        )

        XCTAssertEqual(result, "terminal")
    }
}
