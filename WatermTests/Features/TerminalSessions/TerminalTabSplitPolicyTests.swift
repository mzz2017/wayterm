import XCTest
@testable import Waterm

// Test Context:
// These tests protect pure terminal tab split planning. They use in-memory tab
// and pane state values only; update them when split layout or seeded pane
// semantics intentionally change.

final class TerminalTabSplitPolicyTests: XCTestCase {
    func testSplitRootPaneCreatesLayoutFocusedOnNewPaneAndSeedsFromSourcePane() {
        // Given a single-pane tab and a source pane with working-directory context.
        let serverId = UUID()
        let tab = TerminalTab(serverId: serverId, title: "Main")
        var sourceState = TerminalPaneState(
            paneId: tab.rootPaneId,
            tabId: tab.id,
            serverId: serverId
        )
        sourceState.workingDirectory = "/srv/app"
        let newPaneId = UUID()

        // When the root pane is split.
        let result = TerminalTabSplitPolicy.split(
            tab: tab,
            targetPaneId: tab.rootPaneId,
            newPaneId: newPaneId,
            direction: .horizontal,
            sourcePaneState: sourceState,
            isTmuxEnabled: false
        )

        guard let result else {
            return XCTFail("Root pane split should produce an updated tab and new pane state.")
        }
        // Then the new pane is focused, present in layout order, and seeded from the source pane.
        XCTAssertEqual(result.updatedTab.focusedPaneId, newPaneId)
        XCTAssertEqual(result.updatedTab.allPaneIds, [tab.rootPaneId, newPaneId])
        XCTAssertEqual(result.newPaneState.paneId, newPaneId)
        XCTAssertEqual(result.newPaneState.tabId, tab.id)
        XCTAssertEqual(result.newPaneState.serverId, serverId)
        XCTAssertEqual(result.newPaneState.workingDirectory, "/srv/app")
        XCTAssertEqual(result.newPaneState.seedPaneId, tab.rootPaneId)
        XCTAssertEqual(result.newPaneState.tmuxStatus, .off)
    }

    func testSplitNestedPaneEqualizesLayoutAndMarksTmuxUnknownWhenEnabled() {
        // Given an already split tab and a server whose panes should attach to tmux.
        let serverId = UUID()
        let rootPaneId = UUID()
        let secondPaneId = UUID()
        let tab = TerminalTab(
            serverId: serverId,
            title: "Main",
            rootPaneId: rootPaneId,
            layout: .split(.init(
                direction: .horizontal,
                ratio: 0.5,
                left: .leaf(paneId: rootPaneId),
                right: .leaf(paneId: secondPaneId)
            ))
        )
        let newPaneId = UUID()

        // When one nested pane is split again.
        let result = TerminalTabSplitPolicy.split(
            tab: tab,
            targetPaneId: rootPaneId,
            newPaneId: newPaneId,
            direction: .horizontal,
            sourcePaneState: nil,
            isTmuxEnabled: true
        )

        guard let result,
              case .split(let split) = result.updatedTab.layout
        else {
            return XCTFail("Nested split should produce a split layout.")
        }
        // Then pane ordering and top-level ratio match the equalized split tree.
        XCTAssertEqual(result.updatedTab.allPaneIds, [rootPaneId, newPaneId, secondPaneId])
        XCTAssertEqual(split.ratio, 2.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(result.newPaneState.tmuxStatus, .unknown)
    }

    func testSplitRejectsMissingPane() {
        // Given a tab that does not contain the requested target pane.
        let tab = TerminalTab(serverId: UUID(), title: "Main")

        // When split planning is requested for an unknown pane.
        let result = TerminalTabSplitPolicy.split(
            tab: tab,
            targetPaneId: UUID(),
            newPaneId: UUID(),
            direction: .vertical,
            sourcePaneState: nil,
            isTmuxEnabled: false
        )

        // Then no tab or pane state mutation is planned.
        XCTAssertNil(result)
    }
}
