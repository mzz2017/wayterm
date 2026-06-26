import XCTest
@testable import VVTerm

// Test Context:
// These tests protect scoped pending request bookkeeping shared by
// TerminalSession application request flows. They use inert values only; update
// them when request de-duplication or stale task cleanup semantics
// intentionally change.

final class TerminalScopedRequestStoreTests: XCTestCase {
    func testInsertTracksRequestByRequestAndScope() {
        // Given an empty scoped request store.
        var store = TerminalScopedRequestStore<String>()
        let scopeID = UUID()
        let requestID = UUID()

        // When a request is inserted for a scope.
        store.insert("retry", id: requestID, scopeID: scopeID)

        // Then both request and scope indexes point at the same pending request.
        XCTAssertEqual(store[requestID], "retry")
        XCTAssertEqual(store.requestID(forScope: scopeID), requestID)
        XCTAssertEqual(store.pendingRequestIDs, [requestID])
        XCTAssertEqual(store.pendingScopedRequestIDs, [requestID])
    }

    func testRemoveMappedRequestForScopeReturnsAndClearsRequest() {
        // Given a scope has one pending request.
        var store = TerminalScopedRequestStore<String>()
        let scopeID = UUID()
        let requestID = UUID()
        store.insert("credential-load", id: requestID, scopeID: scopeID)

        // When the request is removed through the scope mapping.
        let removed = store.removeMappedRequest(forScope: scopeID)

        // Then both indexes are cleared and the stored request is returned.
        XCTAssertEqual(removed, "credential-load")
        XCTAssertNil(store[requestID])
        XCTAssertNil(store.requestID(forScope: scopeID))
        XCTAssertTrue(store.pendingRequestIDs.isEmpty)
    }

    func testRemoveScopeMappingKeepsRequestAwaitableByRequestID() {
        // Given a request whose task must remain waitable after lifecycle cancellation.
        var store = TerminalScopedRequestStore<String>()
        let scopeID = UUID()
        let requestID = UUID()
        store.insert("credential-load", id: requestID, scopeID: scopeID)

        // When only the scope mapping is removed.
        let unmapped = store.removeScopeMapping(forScope: scopeID)

        // Then scoped pending state clears while request-id lookup remains available.
        XCTAssertEqual(unmapped, "credential-load")
        XCTAssertNil(store.requestID(forScope: scopeID))
        XCTAssertEqual(store[requestID], "credential-load")
        XCTAssertEqual(store.pendingRequestIDs, [requestID])
        XCTAssertTrue(store.pendingScopedRequestIDs.isEmpty)
    }

    func testRemoveIfMappedDoesNotClearNewerRequestForSameScope() {
        // Given an older task ID and a newer request now mapped to the same scope.
        var store = TerminalScopedRequestStore<String>()
        let scopeID = UUID()
        let oldRequestID = UUID()
        let newRequestID = UUID()
        store.insert("old", id: oldRequestID, scopeID: scopeID)
        store.insert("new", id: newRequestID, scopeID: scopeID)

        // When the old task's defer cleanup runs.
        let removed = store.remove(id: oldRequestID, ifMappedTo: scopeID)

        // Then only the old request is removed; the scope still points at the newer request.
        XCTAssertEqual(removed, "old")
        XCTAssertNil(store[oldRequestID])
        XCTAssertEqual(store[newRequestID], "new")
        XCTAssertEqual(store.requestID(forScope: scopeID), newRequestID)
    }

    func testRemoveAllRequestsForScopeClearsOlderAndVisibleRequests() {
        // Given a scope has a superseded request plus the latest visible request.
        var store = TerminalScopedRequestStore<String>()
        let scopeID = UUID()
        let otherScopeID = UUID()
        let oldRequestID = UUID()
        let newRequestID = UUID()
        let otherRequestID = UUID()
        store.insert("old", id: oldRequestID, scopeID: scopeID)
        store.insert("new", id: newRequestID, scopeID: scopeID)
        store.insert("other", id: otherRequestID, scopeID: otherScopeID)

        // When all requests for that scope are removed.
        let removed = store.removeAllRequests(forScope: scopeID)

        // Then both the superseded and visible requests are returned, and
        // unrelated scopes keep their request and visible mapping.
        XCTAssertEqual(Set(removed), ["old", "new"])
        XCTAssertNil(store[oldRequestID])
        XCTAssertNil(store[newRequestID])
        XCTAssertNil(store.requestID(forScope: scopeID))
        XCTAssertEqual(store[otherRequestID], "other")
        XCTAssertEqual(store.requestID(forScope: otherScopeID), otherRequestID)
    }
}
