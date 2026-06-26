//
//  TerminalTabClosePanePolicy.swift
//  VVTerm
//
//  Pure planning rules for closing a pane from a terminal tab layout.
//

import Foundation

enum TerminalTabClosePanePolicy {
    enum Plan: Equatable {
        case closeTab
        case closePane(updatedTab: TerminalTab)
    }

    static func plan(tab: TerminalTab, paneId: UUID) -> Plan? {
        let paneExists: Bool
        if let layout = tab.layout {
            paneExists = layout.findPane(paneId)
        } else {
            paneExists = tab.rootPaneId == paneId
        }
        guard paneExists else { return nil }

        if tab.paneCount <= 1 {
            return .closeTab
        }

        var updatedTab = tab
        if let currentLayout = tab.layout,
           let newLayout = currentLayout.removingPane(paneId) {
            updatedTab.layout = newLayout.equalized()

            if updatedTab.focusedPaneId == paneId {
                updatedTab.focusedPaneId = newLayout.allPaneIds().first ?? tab.rootPaneId
            }
        }

        return .closePane(updatedTab: updatedTab)
    }
}
