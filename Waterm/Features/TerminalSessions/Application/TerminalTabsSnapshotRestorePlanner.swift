//
//  TerminalTabsSnapshotRestorePlanner.swift
//  Waterm
//
//  Pure restoration planning for persisted terminal tabs.
//

import Foundation

nonisolated struct TerminalTabsSnapshotRestorePlan {
    let tabsByServer: [UUID: [TerminalTab]]
    let selectedTabByServer: [UUID: UUID]
    let selectedViewByServer: [UUID: String]
    let paneStates: [UUID: TerminalPaneState]
}

nonisolated enum TerminalTabsSnapshotRestorePlanner {
    static func plan(
        from snapshot: TerminalTabsSnapshot,
        isTmuxEnabled: (UUID) -> Bool
    ) -> TerminalTabsSnapshotRestorePlan {
        var restoredTabsByServer: [UUID: [TerminalTab]] = [:]
        var restoredSelectedTabs: [UUID: UUID] = [:]
        var restoredSelectedViews: [UUID: String] = [:]
        var snapshotsByTabId: [UUID: TerminalTabsSnapshot.TabSnapshot] = [:]

        for server in snapshot.servers where !server.tabs.isEmpty {
            for tabSnapshot in server.tabs {
                snapshotsByTabId[tabSnapshot.id] = tabSnapshot
            }
            restoredTabsByServer[server.serverId] = server.tabs.map { $0.toTerminalTab() }
            if let selected = server.selectedTabId {
                restoredSelectedTabs[server.serverId] = selected
            }
            if let view = server.selectedView {
                restoredSelectedViews[server.serverId] = view
            }
        }

        return TerminalTabsSnapshotRestorePlan(
            tabsByServer: restoredTabsByServer,
            selectedTabByServer: restoredSelectedTabs,
            selectedViewByServer: restoredSelectedViews,
            paneStates: makeRestoredPaneStates(
                from: restoredTabsByServer,
                snapshotsByTabId: snapshotsByTabId,
                isTmuxEnabled: isTmuxEnabled
            )
        )
    }

    private static func makeRestoredPaneStates(
        from tabsByServer: [UUID: [TerminalTab]],
        snapshotsByTabId: [UUID: TerminalTabsSnapshot.TabSnapshot],
        isTmuxEnabled: (UUID) -> Bool
    ) -> [UUID: TerminalPaneState] {
        var restoredPaneStates: [UUID: TerminalPaneState] = [:]

        for tabs in tabsByServer.values {
            for tab in tabs {
                for paneId in tab.allPaneIds {
                    var paneState = TerminalPaneState(
                        paneId: paneId,
                        tabId: tab.id,
                        serverId: tab.serverId
                    )
                    if !isTmuxEnabled(tab.serverId) {
                        paneState.tmuxStatus = .off
                    }
                    paneState.presentationOverrides = snapshotsByTabId[tab.id]?.panePresentationOverrides?[paneId] ?? .empty
                    restoredPaneStates[paneId] = paneState
                }
            }
        }

        return restoredPaneStates
    }
}
