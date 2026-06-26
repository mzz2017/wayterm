//
//  TerminalPaneRequestStore.swift
//  VVTerm
//
//  Pane-scoped pending request indexing for TerminalSessions application flows.
//

import Foundation

struct TerminalPaneRequestStore<Request> {
    private var requests: [UUID: Request] = [:]
    private var requestByPane: [UUID: UUID] = [:]

    var pendingRequestIDs: Set<UUID> {
        Set(requests.keys)
    }

    var pendingPaneRequestIDs: Set<UUID> {
        Set(requestByPane.values)
    }

    var allRequests: [Request] {
        Array(requests.values)
    }

    subscript(_ requestID: UUID) -> Request? {
        get { requests[requestID] }
        set { requests[requestID] = newValue }
    }

    func requestID(forPane paneId: UUID) -> UUID? {
        requestByPane[paneId]
    }

    mutating func insert(_ request: Request, id requestID: UUID, paneId: UUID) {
        requests[requestID] = request
        requestByPane[paneId] = requestID
    }

    @discardableResult
    mutating func remove(id requestID: UUID, ifMappedTo paneId: UUID) -> Request? {
        let request = requests.removeValue(forKey: requestID)
        if requestByPane[paneId] == requestID {
            requestByPane.removeValue(forKey: paneId)
        }
        return request
    }

    @discardableResult
    mutating func removeMappedRequest(forPane paneId: UUID) -> Request? {
        guard let requestID = requestByPane.removeValue(forKey: paneId) else { return nil }
        return requests.removeValue(forKey: requestID)
    }

    /// Clears pane pending state while keeping the request available by ID for waiters.
    @discardableResult
    mutating func removePaneMapping(forPane paneId: UUID) -> Request? {
        guard let requestID = requestByPane.removeValue(forKey: paneId) else { return nil }
        return requests[requestID]
    }

    mutating func update(_ requestID: UUID, _ mutate: (inout Request) -> Void) {
        guard var request = requests[requestID] else { return }
        mutate(&request)
        requests[requestID] = request
    }

    mutating func removeAll() {
        requests.removeAll()
        requestByPane.removeAll()
    }
}
