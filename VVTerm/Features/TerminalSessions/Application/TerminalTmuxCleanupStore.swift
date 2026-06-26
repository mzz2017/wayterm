//
//  TerminalTmuxCleanupStore.swift
//  VVTerm
//
//  Per-server tmux cleanup bookkeeping.
//

import Foundation

struct TerminalTmuxCleanupStore {
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
