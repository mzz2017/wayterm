import XCTest
@testable import Waterm

// Test Context:
// These tests protect reconnect-in-flight bookkeeping shared by session and
// pane reconnect flows. Update only if reconnect duplicate suppression no
// longer uses per-terminal-entity in-flight gates.

final class TerminalReconnectInFlightStoreTests: XCTestCase {
    func testBeginMarksEntityInFlightAndRejectsDuplicateBegin() {
        // Given an empty reconnect in-flight store.
        var store = TerminalReconnectInFlightStore()
        let entityID = UUID()

        // When reconnect begins for an entity.
        let firstBegin = store.begin(entityID)
        let duplicateBegin = store.begin(entityID)

        // Then the entity is marked in flight and duplicate begins are rejected.
        XCTAssertTrue(firstBegin)
        XCTAssertFalse(duplicateBegin)
        XCTAssertTrue(store.contains(entityID))
        XCTAssertEqual(store.entityIDs, Set([entityID]))
    }

    func testFinishRemovesEntityFromInFlightSet() {
        // Given an entity has a reconnect in flight.
        var store = TerminalReconnectInFlightStore()
        let entityID = UUID()
        store.begin(entityID)

        // When that reconnect finishes.
        store.finish(entityID)

        // Then the entity can begin reconnect again.
        XCTAssertFalse(store.contains(entityID))
        XCTAssertTrue(store.begin(entityID))
    }

    func testRemoveAllClearsEntities() {
        // Given multiple reconnects are tracked.
        var store = TerminalReconnectInFlightStore()
        store.begin(UUID())
        store.begin(UUID())

        // When all reconnect state is cleared.
        store.removeAll()

        // Then the store is empty.
        XCTAssertTrue(store.isEmpty)
        XCTAssertTrue(store.entityIDs.isEmpty)
    }
}
