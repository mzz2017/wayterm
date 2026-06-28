import XCTest
@testable import VVTermConnectionViewsApplicationLogic

// Test Context: protects iOS connection-view selection rules now owned by
// ConnectionViews/Application. Update these tests when visible tab selection
// semantics change, not when UI layout changes.

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
