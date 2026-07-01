//
//  TerminalReconnectInFlightStore.swift
//  Waterm
//
//  Per-terminal-entity reconnect duplicate suppression.
//

import Foundation

nonisolated struct TerminalReconnectInFlightStore {
    private var entities: Set<UUID> = []

    var isEmpty: Bool {
        entities.isEmpty
    }

    var entityIDs: Set<UUID> {
        entities
    }

    func contains(_ entityID: UUID) -> Bool {
        entities.contains(entityID)
    }

    @discardableResult
    mutating func begin(_ entityID: UUID) -> Bool {
        entities.insert(entityID).inserted
    }

    mutating func finish(_ entityID: UUID) {
        entities.remove(entityID)
    }

    mutating func removeAll() {
        entities.removeAll()
    }
}
