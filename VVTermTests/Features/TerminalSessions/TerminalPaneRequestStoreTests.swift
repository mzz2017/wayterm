import XCTest
@testable import VVTerm

// Test Context:
// These tests protect pane-scoped pending request bookkeeping shared by
// TerminalTabManager request flows. They use inert values only; update them
// when pane request de-duplication or stale task cleanup semantics
// intentionally change.

final class TerminalPaneRequestStoreTests: XCTestCase {
    func testInsertTracksRequestByRequestAndPane() {
        // Given an empty pane request store.
        var store = TerminalPaneRequestStore<String>()
        let paneId = UUID()
        let requestID = UUID()

        // When a request is inserted for a pane.
        store.insert("retry", id: requestID, paneId: paneId)

        // Then both request and pane indexes point at the same pending request.
        XCTAssertEqual(store[requestID], "retry")
        XCTAssertEqual(store.requestID(forPane: paneId), requestID)
        XCTAssertEqual(store.pendingRequestIDs, [requestID])
        XCTAssertEqual(store.pendingPaneRequestIDs, [requestID])
    }

    func testRemoveMappedRequestForPaneReturnsAndClearsRequest() {
        // Given a pane has one pending request.
        var store = TerminalPaneRequestStore<String>()
        let paneId = UUID()
        let requestID = UUID()
        store.insert("credential-load", id: requestID, paneId: paneId)

        // When the request is removed through the pane mapping.
        let removed = store.removeMappedRequest(forPane: paneId)

        // Then both indexes are cleared and the stored request is returned.
        XCTAssertEqual(removed, "credential-load")
        XCTAssertNil(store[requestID])
        XCTAssertNil(store.requestID(forPane: paneId))
        XCTAssertTrue(store.pendingRequestIDs.isEmpty)
    }

    func testRemovePaneMappingKeepsRequestAwaitableByRequestID() {
        // Given a pane request whose task must remain waitable after lifecycle cancellation.
        var store = TerminalPaneRequestStore<String>()
        let paneId = UUID()
        let requestID = UUID()
        store.insert("credential-load", id: requestID, paneId: paneId)

        // When only the pane mapping is removed.
        let unmapped = store.removePaneMapping(forPane: paneId)

        // Then pane pending state clears while request-id lookup remains available.
        XCTAssertEqual(unmapped, "credential-load")
        XCTAssertNil(store.requestID(forPane: paneId))
        XCTAssertEqual(store[requestID], "credential-load")
        XCTAssertEqual(store.pendingRequestIDs, [requestID])
        XCTAssertTrue(store.pendingPaneRequestIDs.isEmpty)
    }

    func testRemoveIfMappedDoesNotClearNewerRequestForSamePane() {
        // Given an older task ID and a newer request now mapped to the same pane.
        var store = TerminalPaneRequestStore<String>()
        let paneId = UUID()
        let oldRequestID = UUID()
        let newRequestID = UUID()
        store.insert("old", id: oldRequestID, paneId: paneId)
        store.insert("new", id: newRequestID, paneId: paneId)

        // When the old task's defer cleanup runs.
        let removed = store.remove(id: oldRequestID, ifMappedTo: paneId)

        // Then only the old request is removed; the pane still points at the newer request.
        XCTAssertEqual(removed, "old")
        XCTAssertNil(store[oldRequestID])
        XCTAssertEqual(store[newRequestID], "new")
        XCTAssertEqual(store.requestID(forPane: paneId), newRequestID)
    }
}
