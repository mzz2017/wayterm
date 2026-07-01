import XCTest
@testable import Waterm

// Test Context:
// These tests protect connect-watchdog task bookkeeping used by terminal
// session/pane readiness monitoring. They use inert tasks; update only if
// watchdog lifecycle no longer needs per-entity task and generation tracking.

final class TerminalConnectWatchdogStoreTests: XCTestCase {
    func testBeginGenerationTracksCurrentGeneration() {
        // Given an empty watchdog store.
        var store = TerminalConnectWatchdogStore()
        let entityID = UUID()

        // When a generation starts for an entity.
        let generation = store.beginGeneration(for: entityID)

        // Then only that generation is current for the entity.
        XCTAssertTrue(store.isCurrent(generation, for: entityID))
        XCTAssertFalse(store.isCurrent(UUID(), for: entityID))
        XCTAssertEqual(store.trackedEntityIDs, Set([entityID]))
    }

    func testCancelTaskRemovesOnlyTaskAndKeepsGeneration() {
        // Given an entity has a generation and a task.
        var store = TerminalConnectWatchdogStore()
        let entityID = UUID()
        let generation = store.beginGeneration(for: entityID)
        let task = Task<Void, Never> {}
        store.setTask(task, for: entityID)

        // When the task is cancelled for replacement.
        let removedTask = store.removeTask(for: entityID)

        // Then the generation remains available for the next task.
        XCTAssertEqual(removedTask, task)
        XCTAssertTrue(store.isCurrent(generation, for: entityID))
        XCTAssertEqual(store.trackedEntityIDs, Set([entityID]))
    }

    func testClearRemovesTaskAndGeneration() {
        // Given an entity has a generation and task.
        var store = TerminalConnectWatchdogStore()
        let entityID = UUID()
        let generation = store.beginGeneration(for: entityID)
        let task = Task<Void, Never> {}
        store.setTask(task, for: entityID)

        // When the entity is cleared.
        let removedTask = store.clear(for: entityID)

        // Then both task and generation are removed.
        XCTAssertEqual(removedTask, task)
        XCTAssertFalse(store.isCurrent(generation, for: entityID))
        XCTAssertTrue(store.trackedEntityIDs.isEmpty)
        XCTAssertTrue(store.isEmpty)
    }

    func testRemoveAllClearsAndReturnsTasksToCancel() {
        // Given multiple entities have watchdog tasks.
        var store = TerminalConnectWatchdogStore()
        let firstID = UUID()
        let secondID = UUID()
        let firstTask = Task<Void, Never> {}
        let secondTask = Task<Void, Never> {}
        store.beginGeneration(for: firstID)
        store.beginGeneration(for: secondID)
        store.setTask(firstTask, for: firstID)
        store.setTask(secondTask, for: secondID)

        // When all watchdog state is removed.
        let removedTasks = store.removeAll()

        // Then all tasks are returned for cancellation and state is empty.
        XCTAssertEqual(removedTasks.count, 2)
        XCTAssertTrue(removedTasks.contains(firstTask))
        XCTAssertTrue(removedTasks.contains(secondTask))
        XCTAssertTrue(store.trackedEntityIDs.isEmpty)
        XCTAssertTrue(store.isEmpty)
    }
}
