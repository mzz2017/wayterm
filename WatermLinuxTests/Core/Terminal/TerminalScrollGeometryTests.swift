import XCTest
@testable import WatermTerminalCoreLogic

final class TerminalScrollGeometryTests: XCTestCase {
    func testContentHeightAddsViewportPaddingSoBottomOffsetMapsToLastScrollableRow() {
        let geometry = TerminalScrollGeometry(totalRows: 100, visibleRows: 24, cellHeight: 10)

        XCTAssertEqual(geometry.contentHeight(viewportHeight: 247), 1007)
        XCTAssertEqual(geometry.row(forContentOffsetY: 760), 76)
        XCTAssertEqual(geometry.contentOffsetY(forRow: 76), 760)
    }

    func testRowForContentOffsetClampsToScrollableRange() {
        let geometry = TerminalScrollGeometry(totalRows: 100, visibleRows: 20, cellHeight: 10)

        XCTAssertEqual(geometry.row(forContentOffsetY: -25), 0)
        XCTAssertEqual(geometry.row(forContentOffsetY: 0), 0)
        XCTAssertEqual(geometry.row(forContentOffsetY: 45), 4)
        XCTAssertEqual(geometry.row(forContentOffsetY: 9_999), 80)
    }

    func testContentOffsetForRowClampsToScrollableRange() {
        let geometry = TerminalScrollGeometry(totalRows: 100, visibleRows: 20, cellHeight: 10)

        XCTAssertEqual(geometry.contentOffsetY(forRow: -3), 0)
        XCTAssertEqual(geometry.contentOffsetY(forRow: 8), 80)
        XCTAssertEqual(geometry.contentOffsetY(forRow: 500), 800)
    }

    func testInvalidDimensionsRemainStable() {
        let geometry = TerminalScrollGeometry(totalRows: -1, visibleRows: 0, cellHeight: 0)

        XCTAssertEqual(geometry.maxScrollableRow, 0)
        XCTAssertEqual(geometry.contentHeight(viewportHeight: 500), 500)
        XCTAssertEqual(geometry.row(forContentOffsetY: 300), 0)
        XCTAssertEqual(geometry.contentOffsetY(forRow: 10), 0)
    }

    func testScrollOwnerUsesHostScrollbackWhenNoGestureOrRemoteAppOwnsScroll() {
        let context = TerminalScrollContext(
            remoteScrollOwnerActive: false,
            hasHostScrollableRows: true,
            isSelecting: false,
            isPinching: false
        )

        XCTAssertEqual(TerminalScrollRoutingPolicy.owner(for: context), .hostScrollback)
    }

    func testScrollOwnerRoutesMouseCaptureToRemoteApplication() {
        let context = TerminalScrollContext(
            remoteScrollOwnerActive: true,
            remoteAlternateScreenActive: false,
            hasHostScrollableRows: true,
            isSelecting: false,
            isPinching: false
        )

        XCTAssertEqual(TerminalScrollRoutingPolicy.owner(for: context), .remoteMouseApplication)
    }

    func testScrollOwnerRoutesAlternateScreenToRemoteApplication() {
        let context = TerminalScrollContext(
            remoteScrollOwnerActive: false,
            remoteAlternateScreenActive: true,
            hasHostScrollableRows: true,
            isSelecting: false,
            isPinching: false
        )

        XCTAssertEqual(TerminalScrollRoutingPolicy.owner(for: context), .remoteMouseApplication)
    }

    func testScrollOwnerRoutesToRemoteApplicationWhenHostScrollbackCannotScroll() {
        let context = TerminalScrollContext(
            remoteScrollOwnerActive: false,
            hasHostScrollableRows: false,
            isSelecting: false,
            isPinching: false
        )

        XCTAssertEqual(TerminalScrollRoutingPolicy.owner(for: context), .remoteMouseApplication)
    }

    func testSelectionAndPinchSuppressHostScrolling() {
        XCTAssertEqual(
            TerminalScrollRoutingPolicy.owner(for: TerminalScrollContext(
                remoteScrollOwnerActive: true,
                remoteAlternateScreenActive: false,
                hasHostScrollableRows: false,
                isSelecting: true,
                isPinching: true
            )),
            .selection
        )

        XCTAssertEqual(
            TerminalScrollRoutingPolicy.owner(for: TerminalScrollContext(
                remoteScrollOwnerActive: false,
                remoteAlternateScreenActive: true,
                hasHostScrollableRows: false,
                isSelecting: false,
                isPinching: true
            )),
            .pinchZoom
        )
    }

}
