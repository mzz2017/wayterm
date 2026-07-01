import XCTest
@testable import Waterm

// Test Context:
// These tests protect scoped serial request bookkeeping used by terminal input
// flows. They use inert values and already-completing tasks; update only if
// input ordering no longer depends on per-session/per-pane task chaining.

final class TerminalSerialRequestStoreTests: XCTestCase {
    func testInsertTracksRequestAndLastTaskByScope() {
        // Given an empty serial request store.
        var store = TerminalSerialRequestStore<String>()
        let scopeID = UUID()
        let requestID = UUID()
        let task = Task<Void, Never> {}

        // When a request is inserted for a scope.
        store.insert("input", id: requestID, scopeID: scopeID, task: task)

        // Then request lookup and latest task lookup are both tracked.
        XCTAssertEqual(store[requestID], "input")
        XCTAssertEqual(store.requestID(forScope: scopeID), requestID)
        XCTAssertEqual(store.lastTask(forScope: scopeID), task)
        XCTAssertEqual(store.pendingRequestIDs, [requestID])
    }

    func testRemoveOldRequestDoesNotClearNewerSerialTaskForSameScope() {
        // Given two queued requests for the same scope.
        var store = TerminalSerialRequestStore<String>()
        let scopeID = UUID()
        let oldRequestID = UUID()
        let newRequestID = UUID()
        let oldTask = Task<Void, Never> {}
        let newTask = Task<Void, Never> {}
        store.insert("old", id: oldRequestID, scopeID: scopeID, task: oldTask)
        store.insert("new", id: newRequestID, scopeID: scopeID, task: newTask)

        // When the old task's defer cleanup runs.
        let removed = store.remove(id: oldRequestID, ifLatestForScope: scopeID)

        // Then the newer request remains the visible chain tail.
        XCTAssertEqual(removed, "old")
        XCTAssertNil(store[oldRequestID])
        XCTAssertEqual(store[newRequestID], "new")
        XCTAssertEqual(store.requestID(forScope: scopeID), newRequestID)
        XCTAssertEqual(store.lastTask(forScope: scopeID), newTask)
    }

    func testRemoveAllRequestsForScopeClearsRequestsAndLastTask() {
        // Given a scope has multiple queued requests and another scope exists.
        var store = TerminalSerialRequestStore<String>()
        let scopeID = UUID()
        let otherScopeID = UUID()
        let firstID = UUID()
        let secondID = UUID()
        let otherID = UUID()
        let firstTask = Task<Void, Never> {}
        let secondTask = Task<Void, Never> {}
        let otherTask = Task<Void, Never> {}
        store.insert("first", id: firstID, scopeID: scopeID, task: firstTask)
        store.insert("second", id: secondID, scopeID: scopeID, task: secondTask)
        store.insert("other", id: otherID, scopeID: otherScopeID, task: otherTask)

        // When all requests for the first scope are removed.
        let removed = store.removeAllRequests(forScope: scopeID)

        // Then that scope's request chain is cleared without disturbing the other scope.
        XCTAssertEqual(Set(removed), ["first", "second"])
        XCTAssertNil(store[firstID])
        XCTAssertNil(store[secondID])
        XCTAssertNil(store.requestID(forScope: scopeID))
        XCTAssertNil(store.lastTask(forScope: scopeID))
        XCTAssertEqual(store[otherID], "other")
        XCTAssertEqual(store.requestID(forScope: otherScopeID), otherID)
        XCTAssertEqual(store.lastTask(forScope: otherScopeID), otherTask)
    }
}
