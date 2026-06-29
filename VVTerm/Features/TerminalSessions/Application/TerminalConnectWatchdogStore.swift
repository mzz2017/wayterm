//
//  TerminalConnectWatchdogStore.swift
//  VVTerm
//
//  Per-entity connect watchdog task and generation indexing.
//

import Foundation

nonisolated struct TerminalConnectWatchdogStore {
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var generations: [UUID: UUID] = [:]

    var isEmpty: Bool {
        tasks.isEmpty && generations.isEmpty
    }

    var trackedEntityIDs: Set<UUID> {
        Set(tasks.keys).union(generations.keys)
    }

    @discardableResult
    mutating func beginGeneration(for entityID: UUID) -> UUID {
        let generation = UUID()
        generations[entityID] = generation
        return generation
    }

    func isCurrent(_ generation: UUID, for entityID: UUID) -> Bool {
        generations[entityID] == generation
    }

    mutating func setTask(_ task: Task<Void, Never>, for entityID: UUID) {
        tasks[entityID] = task
    }

    @discardableResult
    mutating func removeTask(for entityID: UUID) -> Task<Void, Never>? {
        tasks.removeValue(forKey: entityID)
    }

    @discardableResult
    mutating func clear(for entityID: UUID) -> Task<Void, Never>? {
        generations.removeValue(forKey: entityID)
        return tasks.removeValue(forKey: entityID)
    }

    @discardableResult
    mutating func removeAll() -> [Task<Void, Never>] {
        let removed = Array(tasks.values)
        tasks.removeAll()
        generations.removeAll()
        return removed
    }
}
