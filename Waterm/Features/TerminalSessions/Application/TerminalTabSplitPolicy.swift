//
//  TerminalTabSplitPolicy.swift
//  Waterm
//
//  Pure planning rules for adding a split pane to an existing terminal tab.
//

import Foundation

nonisolated enum TerminalTabSplitPolicy {
    struct Result: Sendable {
        let updatedTab: TerminalTab
        let newPaneState: TerminalPaneState
    }

    static func split(
        tab: TerminalTab,
        targetPaneId: UUID,
        newPaneId: UUID,
        direction: TerminalSplitDirection,
        sourcePaneState: TerminalPaneState?,
        isTmuxEnabled: Bool
    ) -> Result? {
        let paneExists: Bool
        if let layout = tab.layout {
            paneExists = layout.findPane(targetPaneId)
        } else {
            paneExists = tab.rootPaneId == targetPaneId
        }
        guard paneExists else { return nil }

        var newPaneState = TerminalPaneState(
            paneId: newPaneId,
            tabId: tab.id,
            serverId: tab.serverId
        )
        newPaneState.workingDirectory = sourcePaneState?.workingDirectory
        newPaneState.seedPaneId = targetPaneId
        newPaneState.tmuxStatus = isTmuxEnabled ? .unknown : .off

        let newSplit = TerminalSplitNode.split(TerminalSplitNode.Split(
            direction: direction,
            ratio: 0.5,
            left: .leaf(paneId: targetPaneId),
            right: .leaf(paneId: newPaneId)
        ))

        var updatedTab = tab
        if let currentLayout = tab.layout {
            updatedTab.layout = currentLayout.replacingPane(targetPaneId, with: newSplit).equalized()
        } else {
            updatedTab.layout = newSplit
        }
        updatedTab.focusedPaneId = newPaneId

        return Result(updatedTab: updatedTab, newPaneState: newPaneState)
    }
}
