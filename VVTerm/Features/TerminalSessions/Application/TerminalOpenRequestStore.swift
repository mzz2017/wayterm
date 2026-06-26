//
//  TerminalOpenRequestStore.swift
//  VVTerm
//
//  Pending open request tasks plus per-scope in-flight gates.
//

import Foundation

struct TerminalOpenRequestStore {
    private var requests: [UUID: Task<Void, Never>] = [:]
    private var scopesInFlight: Set<UUID> = []

    var pendingRequestIDs: Set<UUID> {
        Set(requests.keys)
    }

    subscript(_ requestID: UUID) -> Task<Void, Never>? {
        requests[requestID]
    }

    mutating func insert(_ task: Task<Void, Never>, id requestID: UUID) {
        requests[requestID] = task
    }

    @discardableResult
    mutating func remove(id requestID: UUID) -> Task<Void, Never>? {
        requests.removeValue(forKey: requestID)
    }

    mutating func beginOpen(forScope scopeID: UUID) -> Bool {
        guard !scopesInFlight.contains(scopeID) else { return false }
        scopesInFlight.insert(scopeID)
        return true
    }

    mutating func finishOpen(forScope scopeID: UUID) {
        scopesInFlight.remove(scopeID)
    }

    @discardableResult
    mutating func removeAll() -> [Task<Void, Never>] {
        let tasks = Array(requests.values)
        requests.removeAll()
        scopesInFlight.removeAll()
        return tasks
    }
}
