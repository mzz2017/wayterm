//
//  TerminalScopedRequestStore.swift
//  Waterm
//
//  Scoped pending request indexing for TerminalSessions application flows.
//

import Foundation

nonisolated struct TerminalScopedRequestStore<Request> {
    private var requests: [UUID: Request] = [:]
    private var requestByScope: [UUID: UUID] = [:]
    private var scopeByRequest: [UUID: UUID] = [:]

    var pendingRequestIDs: Set<UUID> {
        Set(requests.keys)
    }

    var pendingScopedRequestIDs: Set<UUID> {
        Set(requestByScope.values)
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
                requests.removeValue(forKey: requestID)
                if let scopeID = scopeByRequest.removeValue(forKey: requestID),
                   requestByScope[scopeID] == requestID {
                    requestByScope.removeValue(forKey: scopeID)
                }
            }
        }
    }

    func requestID(forScope scopeID: UUID) -> UUID? {
        requestByScope[scopeID]
    }

    func requests(forScope scopeID: UUID) -> [Request] {
        scopeByRequest.compactMap { requestID, mappedScopeID in
            mappedScopeID == scopeID ? requests[requestID] : nil
        }
    }

    mutating func insert(_ request: Request, id requestID: UUID, scopeID: UUID) {
        if let oldScopeID = scopeByRequest[requestID],
           requestByScope[oldScopeID] == requestID {
            requestByScope.removeValue(forKey: oldScopeID)
        }
        requests[requestID] = request
        requestByScope[scopeID] = requestID
        scopeByRequest[requestID] = scopeID
    }

    @discardableResult
    mutating func remove(id requestID: UUID, ifMappedTo scopeID: UUID) -> Request? {
        let request = requests.removeValue(forKey: requestID)
        scopeByRequest.removeValue(forKey: requestID)
        if requestByScope[scopeID] == requestID {
            requestByScope.removeValue(forKey: scopeID)
        }
        return request
    }

    @discardableResult
    mutating func removeMappedRequest(forScope scopeID: UUID) -> Request? {
        guard let requestID = requestByScope.removeValue(forKey: scopeID) else { return nil }
        scopeByRequest.removeValue(forKey: requestID)
        return requests.removeValue(forKey: requestID)
    }

    /// Clears scoped pending state while keeping the request available by ID for waiters.
    @discardableResult
    mutating func removeScopeMapping(forScope scopeID: UUID) -> Request? {
        guard let requestID = requestByScope.removeValue(forKey: scopeID) else { return nil }
        return requests[requestID]
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
        return removed
    }

    mutating func update(_ requestID: UUID, _ mutate: (inout Request) -> Void) {
        guard var request = requests[requestID] else { return }
        mutate(&request)
        requests[requestID] = request
    }

    mutating func removeAll() {
        requests.removeAll()
        requestByScope.removeAll()
        scopeByRequest.removeAll()
    }
}
