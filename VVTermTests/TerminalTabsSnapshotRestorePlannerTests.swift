import Foundation
import Testing
@testable import VVTerm

// Test Context:
// These tests protect pure terminal tab snapshot restoration planning. They use
// in-memory Codable snapshots only; update them when restored tab selection,
// pane state defaults, or persisted presentation override semantics intentionally
// change.

struct TerminalTabsSnapshotRestorePlannerTests {
    @Test
    func planRestoresTabsSelectionsViewsAndPaneStates() throws {
        // Given a persisted split-tab snapshot with a focused pane and selected view.
        let serverId = UUID()
        let tabId = UUID()
        let rootPaneId = UUID()
        let secondPaneId = UUID()
        let layout = TerminalSplitNode.split(.init(
            direction: .horizontal,
            ratio: 0.5,
            left: .leaf(paneId: rootPaneId),
            right: .leaf(paneId: secondPaneId)
        ))
        let tab = TerminalTab(
            id: tabId,
            serverId: serverId,
            title: "Main",
            createdAt: Date(timeIntervalSince1970: 10),
            rootPaneId: rootPaneId,
            focusedPaneId: secondPaneId,
            layout: layout
        )
        var secondPaneState = TerminalPaneState(
            paneId: secondPaneId,
            tabId: tabId,
            serverId: serverId
        )
        secondPaneState.presentationOverrides = TerminalPresentationOverrides(fontSize: 18)
        let snapshot = TerminalTabsSnapshot(servers: [
            .init(
                serverId: serverId,
                tabs: [
                    .init(from: tab, paneStates: [secondPaneId: secondPaneState])
                ],
                selectedTabId: tabId,
                selectedView: "stats"
            )
        ])

        // When the snapshot is planned for restoration on a tmux-enabled server.
        let plan = TerminalTabsSnapshotRestorePlanner.plan(
            from: snapshot,
            isTmuxEnabled: { $0 == serverId }
        )

        // Then restored app state matches the persisted tab graph and selection.
        let restoredTab = try #require(plan.tabsByServer[serverId]?.first)
        #expect(restoredTab.id == tabId)
        #expect(restoredTab.allPaneIds == [rootPaneId, secondPaneId])
        #expect(restoredTab.focusedPaneId == secondPaneId)
        #expect(plan.selectedTabByServer[serverId] == tabId)
        #expect(plan.selectedViewByServer[serverId] == "stats")

        // And every restored pane has fresh runtime state with persisted presentation overrides.
        #expect(plan.paneStates[rootPaneId]?.tmuxStatus == .unknown)
        #expect(plan.paneStates[secondPaneId]?.tmuxStatus == .unknown)
        #expect(plan.paneStates[secondPaneId]?.presentationOverrides.fontSize == 18)
    }

    @Test
    func planMarksRestoredPaneTmuxOffWhenServerDisablesTmux() throws {
        // Given a persisted single-pane tab for a server without tmux attachment.
        let serverId = UUID()
        let paneId = UUID()
        let tab = TerminalTab(
            id: UUID(),
            serverId: serverId,
            title: "Main",
            createdAt: Date(timeIntervalSince1970: 20),
            rootPaneId: paneId,
            focusedPaneId: paneId,
            layout: nil
        )
        let snapshot = TerminalTabsSnapshot(servers: [
            .init(
                serverId: serverId,
                tabs: [
                    .init(from: tab, paneStates: [:])
                ],
                selectedTabId: nil,
                selectedView: nil
            )
        ])

        // When the snapshot is planned for restoration on a non-tmux server.
        let plan = TerminalTabsSnapshotRestorePlanner.plan(
            from: snapshot,
            isTmuxEnabled: { _ in false }
        )

        // Then restored pane state starts with tmux explicitly disabled.
        #expect(plan.paneStates[paneId]?.tmuxStatus == .off)
        #expect(plan.selectedTabByServer[serverId] == nil)
        #expect(plan.selectedViewByServer[serverId] == nil)
    }
}
