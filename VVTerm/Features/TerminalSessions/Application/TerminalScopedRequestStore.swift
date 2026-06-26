//
//  TerminalScopedRequestStore.swift
//  VVTerm
//
//  Scoped pending request indexing for TerminalSessions application flows.
//

import Foundation

struct TerminalScopedRequestStore<Request> {
    private var requests: [UUID: Request] = [:]
    private var requestByScope: [UUID: UUID] = [:]

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
        set { requests[requestID] = newValue }
    }

    func requestID(forScope scopeID: UUID) -> UUID? {
        requestByScope[scopeID]
    }

    mutating func insert(_ request: Request, id requestID: UUID, scopeID: UUID) {
        requests[requestID] = request
        requestByScope[scopeID] = requestID
    }

    @discardableResult
    mutating func remove(id requestID: UUID, ifMappedTo scopeID: UUID) -> Request? {
        let request = requests.removeValue(forKey: requestID)
        if requestByScope[scopeID] == requestID {
            requestByScope.removeValue(forKey: scopeID)
        }
        return request
    }

    @discardableResult
    mutating func removeMappedRequest(forScope scopeID: UUID) -> Request? {
        guard let requestID = requestByScope.removeValue(forKey: scopeID) else { return nil }
        return requests.removeValue(forKey: requestID)
    }

    /// Clears scoped pending state while keeping the request available by ID for waiters.
    @discardableResult
    mutating func removeScopeMapping(forScope scopeID: UUID) -> Request? {
        guard let requestID = requestByScope.removeValue(forKey: scopeID) else { return nil }
        return requests[requestID]
    }

    mutating func update(_ requestID: UUID, _ mutate: (inout Request) -> Void) {
        guard var request = requests[requestID] else { return }
        mutate(&request)
        requests[requestID] = request
    }

    mutating func removeAll() {
        requests.removeAll()
        requestByScope.removeAll()
    }
}
