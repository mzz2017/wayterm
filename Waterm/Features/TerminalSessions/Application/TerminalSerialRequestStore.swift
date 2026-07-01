//
//  TerminalSerialRequestStore.swift
//  Waterm
//
//  Scoped serial pending request chains for TerminalSessions application flows.
//

import Foundation

nonisolated struct TerminalSerialRequestStore<Request> {
    private var requests: [UUID: Request] = [:]
    private var requestByScope: [UUID: UUID] = [:]
    private var scopeByRequest: [UUID: UUID] = [:]
    private var lastTaskByScope: [UUID: Task<Void, Never>] = [:]

    var pendingRequestIDs: Set<UUID> {
        Set(requests.keys)
    }

    var allRequests: [Request] {
        Array(requests.values)
    }

    subscript(_ requestID: UUID) -> Request? {
        get { requests[requestID] }
        set {
            if let newValue {
                requests[requestID] = newValue
            } else {
                remove(id: requestID)
            }
        }
    }

    func requestID(forScope scopeID: UUID) -> UUID? {
        requestByScope[scopeID]
    }

    func lastTask(forScope scopeID: UUID) -> Task<Void, Never>? {
        lastTaskByScope[scopeID]
    }

    mutating func insert(_ request: Request, id requestID: UUID, scopeID: UUID, task: Task<Void, Never>) {
        if let oldScopeID = scopeByRequest[requestID],
           requestByScope[oldScopeID] == requestID {
            requestByScope.removeValue(forKey: oldScopeID)
            lastTaskByScope.removeValue(forKey: oldScopeID)
        }
        requests[requestID] = request
        requestByScope[scopeID] = requestID
        scopeByRequest[requestID] = scopeID
        lastTaskByScope[scopeID] = task
    }

    @discardableResult
    mutating func remove(id requestID: UUID, ifLatestForScope scopeID: UUID) -> Request? {
        let request = requests.removeValue(forKey: requestID)
        scopeByRequest.removeValue(forKey: requestID)
        if requestByScope[scopeID] == requestID {
            requestByScope.removeValue(forKey: scopeID)
            lastTaskByScope.removeValue(forKey: scopeID)
        }
        return request
    }

    @discardableResult
    mutating func removeAllRequests(forScope scopeID: UUID) -> [Request] {
        let requestIDs = scopeByRequest.compactMap { requestID, mappedScopeID in
            mappedScopeID == scopeID ? requestID : nil
        }
        let removed = requestIDs.compactMap { requestID in
            scopeByRequest.removeValue(forKey: requestID)
            return requests.removeValue(forKey: requestID)
        }
        requestByScope.removeValue(forKey: scopeID)
        lastTaskByScope.removeValue(forKey: scopeID)
        return removed
    }

    mutating func removeAll() {
        requests.removeAll()
        requestByScope.removeAll()
        scopeByRequest.removeAll()
        lastTaskByScope.removeAll()
    }

    @discardableResult
    private mutating func remove(id requestID: UUID) -> Request? {
        guard let scopeID = scopeByRequest[requestID] else {
            return requests.removeValue(forKey: requestID)
        }
        return remove(id: requestID, ifLatestForScope: scopeID)
    }
}
