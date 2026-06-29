//
//  TerminalServerTaskStore.swift
//  VVTerm
//
//  One-task-per-server lifecycle gate indexing.
//

import Foundation

nonisolated struct TerminalServerTaskStore {
    private var tasks: [UUID: Task<Void, Never>] = [:]

    var isEmpty: Bool {
        tasks.isEmpty
    }

    var serverIDs: Set<UUID> {
        Set(tasks.keys)
    }

    func task(forServer serverID: UUID) -> Task<Void, Never>? {
        tasks[serverID]
    }

    mutating func setTask(_ task: Task<Void, Never>?, forServer serverID: UUID) {
        if let task {
            tasks[serverID] = task
        } else {
            tasks.removeValue(forKey: serverID)
        }
    }

    @discardableResult
    mutating func removeTask(forServer serverID: UUID) -> Task<Void, Never>? {
        tasks.removeValue(forKey: serverID)
    }

    @discardableResult
    mutating func removeAll() -> [Task<Void, Never>] {
        let removed = Array(tasks.values)
        tasks.removeAll()
        return removed
    }
}
