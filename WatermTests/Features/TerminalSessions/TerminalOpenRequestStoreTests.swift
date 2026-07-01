import XCTest
@testable import Waterm

// Test Context:
// These tests protect open-request bookkeeping used by terminal tab/session
// creation flows. They use inert already-completing tasks; update only if
// opening no longer needs request waiting or per-server in-flight gating.

final class TerminalOpenRequestStoreTests: XCTestCase {
    func testInsertTracksPendingRequestTask() {
        // Given an empty open request store.
        var store = TerminalOpenRequestStore<Task<Void, Never>>()
        let requestID = UUID()
        let task = Task<Void, Never> {}

        // When a request task is inserted.
        store.insert(task, id: requestID)

        // Then the task is visible to waiters and pending request IDs.
        XCTAssertEqual(store[requestID], task)
        XCTAssertEqual(store.pendingRequestIDs, [requestID])
    }

    func testBeginOpenRejectsDuplicateScopeUntilFinished() {
        // Given an empty open request store.
        var store = TerminalOpenRequestStore<Task<Void, Never>>()
        let scopeID = UUID()

        // When opening begins for a scope.
        let firstBegin = store.beginOpen(forScope: scopeID)
        let duplicateBegin = store.beginOpen(forScope: scopeID)

        // Then duplicate opens are rejected until the scope is finished.
        XCTAssertTrue(firstBegin)
        XCTAssertFalse(duplicateBegin)

        store.finishOpen(forScope: scopeID)
        XCTAssertTrue(store.beginOpen(forScope: scopeID))
    }

    func testRequestScopeMapsDuplicateIntentToExistingRequest() {
        // Given an open request store with a scoped request.
        var store = TerminalOpenRequestStore<Task<Void, Never>>()
        let serverID = UUID()
        let requestID = UUID()
        let scope = TerminalOpenRequestScope(serverId: serverID, kind: .tabOpen)
        let task = Task<Void, Never> {}

        store.insert(task, id: requestID, scope: scope)

        // Then the same user intent can join the existing request until it is removed.
        XCTAssertEqual(store.requestID(forScope: scope), requestID)

        store.remove(id: requestID)

        XCTAssertNil(store.requestID(forScope: scope))
    }

    func testRemoveAllCancelsRequestsAndClearsInFlightScopes() {
        // Given pending requests and in-flight scopes.
        var store = TerminalOpenRequestStore<Task<Void, Never>>()
        let requestID = UUID()
        let scopeID = UUID()
        let task = Task<Void, Never> {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        store.insert(task, id: requestID)
        XCTAssertTrue(store.beginOpen(forScope: scopeID))

        // When all tracked open state is removed.
        let removedTasks = store.removeAll()
        removedTasks.forEach { $0.cancel() }

        // Then request and in-flight state are cleared together.
        XCTAssertEqual(removedTasks, [task])
        XCTAssertTrue(store.pendingRequestIDs.isEmpty)
        XCTAssertTrue(store.beginOpen(forScope: scopeID))
    }
}
