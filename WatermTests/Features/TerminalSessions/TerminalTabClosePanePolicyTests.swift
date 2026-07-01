import XCTest
@testable import Waterm

// Test Context:
// These tests protect pure terminal pane close planning. They use in-memory tab
// layout values only; update them when close-pane layout removal, focus
// fallback, or single-pane close semantics intentionally change.

final class TerminalTabClosePanePolicyTests: XCTestCase {
    func testPlanRejectsMissingPane() {
        // Given a single-pane tab that does not contain the requested pane.
        let tab = TerminalTab(serverId: UUID(), title: "Main")

        // When close planning targets an unknown pane.
        let plan = TerminalTabClosePanePolicy.plan(tab: tab, paneId: UUID())

        // Then no UI mutation is planned.
        XCTAssertNil(plan)
    }

    func testPlanRequestsTabCloseForOnlyPane() {
        // Given a tab with only its root pane.
        let tab = TerminalTab(serverId: UUID(), title: "Main")

        // When close planning targets that only pane.
        let plan = TerminalTabClosePanePolicy.plan(tab: tab, paneId: tab.rootPaneId)

        // Then the caller should close the whole tab instead of leaving an empty layout.
        XCTAssertEqual(plan, .closeTab)
    }

    func testPlanRemovesPaneAndMovesFocusToRemainingPane() {
        // Given a two-pane tab focused on the pane being closed.
        let serverId = UUID()
        let rootPaneId = UUID()
        let closingPaneId = UUID()
        let tab = TerminalTab(
            serverId: serverId,
            title: "Main",
            rootPaneId: rootPaneId,
            focusedPaneId: closingPaneId,
            layout: .split(.init(
                direction: .horizontal,
                ratio: 0.5,
                left: .leaf(paneId: rootPaneId),
                right: .leaf(paneId: closingPaneId)
            ))
        )

        // When close planning removes the focused pane.
        let plan = TerminalTabClosePanePolicy.plan(tab: tab, paneId: closingPaneId)

        // Then the layout keeps the remaining pane and focus moves to it.
        guard case .closePane(let updatedTab)? = plan else {
            return XCTFail("Closing one pane in a split tab should update tab layout.")
        }
        XCTAssertEqual(updatedTab.allPaneIds, [rootPaneId])
        XCTAssertEqual(updatedTab.focusedPaneId, rootPaneId)
    }
}
