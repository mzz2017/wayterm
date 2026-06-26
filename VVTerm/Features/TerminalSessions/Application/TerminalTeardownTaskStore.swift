//
//  TerminalTeardownTaskStore.swift
//  VVTerm
//
//  Per-server teardown task indexing for terminal close/open ordering.
//

import Foundation

struct TerminalTeardownTaskStore {
    struct Entry {
        let id: UUID
        let task: Task<Void, Never>
    }

    private var tasksByServer: [UUID: [UUID: Task<Void, Never>]] = [:]

    var isEmpty: Bool {
        tasksByServer.isEmpty
    }

    var serverIDs: [UUID] {
        Array(tasksByServer.keys)
    }

    func count(forServer serverID: UUID) -> Int {
        tasksByServer[serverID]?.count ?? 0
    }

    func tasks(forServer serverID: UUID) -> [Entry] {
        tasksByServer[serverID]?.map { taskID, task in
            Entry(id: taskID, task: task)
        } ?? []
    }

    @discardableResult
    mutating func insert(_ task: Task<Void, Never>, forServer serverID: UUID) -> UUID {
        let taskID = UUID()
        tasksByServer[serverID, default: [:]][taskID] = task
        return taskID
    }

    @discardableResult
    mutating func finish(_ taskID: UUID, forServer serverID: UUID) -> Int? {
        guard tasksByServer[serverID]?.removeValue(forKey: taskID) != nil else { return nil }
        if tasksByServer[serverID]?.isEmpty == true {
            tasksByServer.removeValue(forKey: serverID)
        }
        return count(forServer: serverID)
    }

    mutating func removeAll() {
        tasksByServer.removeAll()
    }
}
