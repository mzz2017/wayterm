import XCTest
@testable import Waterm

// Test Context:
// These tests protect shell lifecycle handler bookkeeping used when a terminal
// session is closed or suspended. They use in-memory handlers; update only if
// cancel and suspend handlers stop sharing the same session lifecycle boundary.

final class TerminalShellHandlerStoreTests: XCTestCase {
    @MainActor
    func testTakeCancelHandlerRemovesCancelAndSuspendHandlers() async {
        // Given a session has both shell cancel and suspend handlers.
        var store = TerminalShellHandlerStore()
        let sessionID = UUID()
        var cancelModes: [ShellTeardownMode] = []
        var suspendCount = 0
        store.registerCancelHandler({ mode in
            cancelModes.append(mode)
        }, for: sessionID)
        store.registerSuspendHandler({
            suspendCount += 1
        }, for: sessionID)

        // When the cancel handler is taken for terminal teardown.
        let cancelHandler = store.takeCancelHandler(for: sessionID)

        // Then both handlers leave the store, but the taken cancel handler remains runnable.
        await cancelHandler?(.fullDisconnect)
        await store.suspendHandler(for: sessionID)?()
        XCTAssertEqual(cancelModes, [.fullDisconnect])
        XCTAssertEqual(suspendCount, 0)
        XCTAssertTrue(store.isEmpty)
    }

    @MainActor
    func testUnregisterCancelHandlerKeepsSuspendHandler() async {
        // Given a session has independently registered handlers.
        var store = TerminalShellHandlerStore()
        let sessionID = UUID()
        var suspendCount = 0
        store.registerCancelHandler({ _ in }, for: sessionID)
        store.registerSuspendHandler({
            suspendCount += 1
        }, for: sessionID)

        // When only the cancel handler is unregistered.
        store.unregisterCancelHandler(for: sessionID)

        // Then suspend handling remains available for background suspension.
        await store.suspendHandler(for: sessionID)?()
        XCTAssertEqual(suspendCount, 1)
        XCTAssertFalse(store.isEmpty)
    }

    func testRemoveAllClearsHandlers() {
        // Given multiple sessions have registered shell lifecycle handlers.
        var store = TerminalShellHandlerStore()
        store.registerCancelHandler({ _ in }, for: UUID())
        store.registerSuspendHandler({}, for: UUID())

        // When all shell handlers are removed.
        store.removeAll()

        // Then the store is empty.
        XCTAssertTrue(store.isEmpty)
    }
}
