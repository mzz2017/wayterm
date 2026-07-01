import XCTest
@testable import Waterm

// Test Context:
// These tests protect per-server teardown task bookkeeping used by terminal
// close/open ordering. They use inert already-completing tasks; update only if
// opens no longer need to wait for tracked per-server teardown work.

final class TerminalTeardownTaskStoreTests: XCTestCase {
    func testInsertTracksTaskByServerAndReturnsStableTaskID() {
        // Given an empty teardown task store.
        var store = TerminalTeardownTaskStore()
        let serverID = UUID()
        let task = Task<Void, Never> {}

        // When a teardown task is inserted for a server.
        let taskID = store.insert(task, forServer: serverID)

        // Then the task is visible by server and has a stable generated ID.
        XCTAssertEqual(store.count(forServer: serverID), 1)
        XCTAssertEqual(store.tasks(forServer: serverID).map(\.id), [taskID])
        XCTAssertEqual(store.tasks(forServer: serverID).map(\.task), [task])
        XCTAssertEqual(store.serverIDs, [serverID])
    }

    func testFinishRemovesServerWhenLastTaskCompletes() {
        // Given one server has two tracked teardown tasks.
        var store = TerminalTeardownTaskStore()
        let serverID = UUID()
        let firstTaskID = store.insert(Task<Void, Never> {}, forServer: serverID)
        let secondTaskID = store.insert(Task<Void, Never> {}, forServer: serverID)

        // When each task is finished.
        let firstRemaining = store.finish(firstTaskID, forServer: serverID)
        let secondRemaining = store.finish(secondTaskID, forServer: serverID)

        // Then the server entry is removed after the last task.
        XCTAssertEqual(firstRemaining, 1)
        XCTAssertEqual(secondRemaining, 0)
        XCTAssertTrue(store.tasks(forServer: serverID).isEmpty)
        XCTAssertTrue(store.serverIDs.isEmpty)
        XCTAssertTrue(store.isEmpty)
    }

    func testFinishUnknownTaskDoesNotMutateServerTasks() {
        // Given a server has a tracked teardown task.
        var store = TerminalTeardownTaskStore()
        let serverID = UUID()
        let taskID = store.insert(Task<Void, Never> {}, forServer: serverID)

        // When an unknown task is finished.
        let remaining = store.finish(UUID(), forServer: serverID)

        // Then the original task remains tracked.
        XCTAssertNil(remaining)
        XCTAssertEqual(store.tasks(forServer: serverID).map(\.id), [taskID])
        XCTAssertFalse(store.isEmpty)
    }
}
