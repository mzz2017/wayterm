import XCTest
@testable import VVTerm

// Test Context:
// These tests protect per-server tmux cleanup bookkeeping shared by session
// and pane flows. Update only if tmux cleanup no longer needs to persist the
// resolver's cleaned-server set across attach attempts.

final class TerminalTmuxCleanupStoreTests: XCTestCase {
    func testReplaceTracksCleanedServerIDs() {
        // Given an empty tmux cleanup store.
        var store = TerminalTmuxCleanupStore()
        let firstServerID = UUID()
        let secondServerID = UUID()

        // When resolver-updated cleanup state is saved.
        store.replace(with: Set([firstServerID, secondServerID]))

        // Then the store exposes the cleaned server IDs for the next resolver run.
        XCTAssertEqual(store.serverIDs, Set([firstServerID, secondServerID]))
        XCTAssertFalse(store.isEmpty)
    }

    func testRemoveAllClearsCleanupState() {
        // Given cleanup state has been saved.
        var store = TerminalTmuxCleanupStore()
        store.replace(with: Set([UUID()]))

        // When all state is removed.
        store.removeAll()

        // Then the store is empty.
        XCTAssertTrue(store.serverIDs.isEmpty)
        XCTAssertTrue(store.isEmpty)
    }
}
