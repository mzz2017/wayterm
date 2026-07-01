//
//  TerminalOpenRequestStore.swift
//  VVTerm
//
//  Pending open request tasks plus per-scope in-flight gates.
//

import Foundation

nonisolated struct TerminalOpenRequestScope: Hashable {
    enum Kind: Hashable {
        case connectionOpen(forceNew: Bool)
        case serverTerminalOpen
        case tabOpen
    }

    let serverId: UUID
    let kind: Kind
}

nonisolated struct TerminalOpenRequestStore<Request> {
    private var requests: [UUID: Request] = [:]
    private var scopeByRequestID: [UUID: TerminalOpenRequestScope] = [:]
    private var requestIDByScope: [TerminalOpenRequestScope: UUID] = [:]
    private var scopesInFlight: Set<UUID> = []

    var pendingRequestIDs: Set<UUID> {
        Set(requests.keys)
    }

    subscript(_ requestID: UUID) -> Request? {
        requests[requestID]
    }

    func requestID(forScope scope: TerminalOpenRequestScope) -> UUID? {
        requestIDByScope[scope]
    }

    mutating func insert(_ request: Request, id requestID: UUID, scope: TerminalOpenRequestScope? = nil) {
        requests[requestID] = request
        if let scope {
            scopeByRequestID[requestID] = scope
            requestIDByScope[scope] = requestID
        }
    }

    mutating func update(_ requestID: UUID, _ update: (inout Request) -> Void) {
        guard var request = requests[requestID] else { return }
        update(&request)
        requests[requestID] = request
    }

    @discardableResult
    mutating func remove(id requestID: UUID) -> Request? {
        if let scope = scopeByRequestID.removeValue(forKey: requestID),
           requestIDByScope[scope] == requestID {
            requestIDByScope.removeValue(forKey: scope)
        }
        return requests.removeValue(forKey: requestID)
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
    mutating func removeAll() -> [Request] {
        let allRequests = Array(requests.values)
        requests.removeAll()
        scopeByRequestID.removeAll()
        requestIDByScope.removeAll()
        scopesInFlight.removeAll()
        return allRequests
    }
}
