import XCTest
@testable import Waterm

// Test Context:
// These tests protect one-task-per-server bookkeeping used for explicit server
// disconnect gates. They use inert tasks; update only if server-scoped lifecycle
// gates intentionally allow multiple active tasks per server.

final class TerminalServerTaskStoreTests: XCTestCase {
    func testSetAndLookupTaskForServer() {
        // Given an empty server task store.
        var store = TerminalServerTaskStore()
        let serverID = UUID()
        let task = Task<Void, Never> {}

        // When a task is set for a server.
        store.setTask(task, forServer: serverID)

        // Then the task is addressable by that server ID.
        XCTAssertEqual(store.task(forServer: serverID), task)
        XCTAssertEqual(store.serverIDs, Set([serverID]))
        XCTAssertFalse(store.isEmpty)
    }

    func testRemoveTaskClearsOnlyThatServer() {
        // Given two servers have tracked tasks.
        var store = TerminalServerTaskStore()
        let firstServerID = UUID()
        let secondServerID = UUID()
        let firstTask = Task<Void, Never> {}
        let secondTask = Task<Void, Never> {}
        store.setTask(firstTask, forServer: firstServerID)
        store.setTask(secondTask, forServer: secondServerID)

        // When one server task is removed.
        let removedTask = store.removeTask(forServer: firstServerID)

        // Then the other server task remains tracked.
        XCTAssertEqual(removedTask, firstTask)
        XCTAssertNil(store.task(forServer: firstServerID))
        XCTAssertEqual(store.task(forServer: secondServerID), secondTask)
        XCTAssertEqual(store.serverIDs, Set([secondServerID]))
    }

    func testRemoveAllClearsAndReturnsTasksToCancel() {
        // Given multiple servers have tracked tasks.
        var store = TerminalServerTaskStore()
        let firstTask = Task<Void, Never> {}
        let secondTask = Task<Void, Never> {}
        store.setTask(firstTask, forServer: UUID())
        store.setTask(secondTask, forServer: UUID())

        // When all server task state is removed.
        let removedTasks = store.removeAll()

        // Then all tasks are returned for caller-owned cancellation.
        XCTAssertEqual(removedTasks.count, 2)
        XCTAssertTrue(removedTasks.contains(firstTask))
        XCTAssertTrue(removedTasks.contains(secondTask))
        XCTAssertTrue(store.isEmpty)
        XCTAssertTrue(store.serverIDs.isEmpty)
    }
}
