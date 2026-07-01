//
//  TerminalTmuxCleanupStore.swift
//  Waterm
//
//  Per-server tmux cleanup bookkeeping.
//

import Foundation

nonisolated struct TerminalTmuxCleanupStore {
    private var cleanedServerIDs: Set<UUID> = []

    var isEmpty: Bool {
        cleanedServerIDs.isEmpty
    }

    var serverIDs: Set<UUID> {
        cleanedServerIDs
    }

    mutating func replace(with serverIDs: Set<UUID>) {
        cleanedServerIDs = serverIDs
    }

    mutating func removeAll() {
        cleanedServerIDs.removeAll()
    }
}
