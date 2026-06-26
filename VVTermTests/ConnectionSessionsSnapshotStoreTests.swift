import Foundation
import Testing
@testable import VVTerm

// Test Context:
// These tests protect connection session snapshot persistence after storage
// encoding moved out of ConnectionSessionManager. They use isolated UserDefaults
// suites and no live SSH or terminal runtime; update only when the snapshot
// persistence contract or storage key injection behavior intentionally changes.

struct ConnectionSessionsSnapshotStoreTests {
    @Test
    func saveThenLoadRoundTripsSnapshot() throws {
        let (store, defaults) = makeStore()
        let serverId = UUID()
        let sessionId = UUID()
        let createdAt = Date(timeIntervalSince1970: 1_234)
        let lastActivity = Date(timeIntervalSince1970: 2_345)
        let session = ConnectionSession(
            id: sessionId,
            serverId: serverId,
            title: "Main",
            connectionState: .connected,
            createdAt: createdAt,
            lastActivity: lastActivity,
            workingDirectory: "/srv/app"
        )
        let snapshot = ConnectionSessionsSnapshot(
            sessions: [.init(from: session)],
            selectedSessionId: sessionId,
            serverSelections: [
                .init(serverId: serverId, selectedSessionId: sessionId, selectedView: "terminal")
            ]
        )

        // When the store saves and reloads a snapshot.
        try store.save(snapshot)
        let loaded = try #require(try store.load())

        // Then the persisted session shape round-trips through UserDefaults.
        #expect(defaults.data(forKey: "connectionSessionsSnapshot.v1") != nil)
        #expect(loaded.sessions.first?.id == sessionId)
        #expect(loaded.sessions.first?.title == "Main")
        #expect(loaded.sessions.first?.workingDirectory == "/srv/app")
        #expect(loaded.selectedSessionId == sessionId)
        #expect(loaded.serverSelections.first?.selectedView == "terminal")
    }

    @Test
    func removeClearsStoredSnapshot() throws {
        let (store, defaults) = makeStore()
        let snapshot = ConnectionSessionsSnapshot(
            sessions: [],
            selectedSessionId: nil,
            serverSelections: []
        )

        // Given a persisted snapshot exists.
        try store.save(snapshot)
        #expect(defaults.data(forKey: "connectionSessionsSnapshot.v1") != nil)

        // When the store removes it.
        store.remove()

        // Then future loads report no snapshot.
        #expect(defaults.data(forKey: "connectionSessionsSnapshot.v1") == nil)
        #expect(try store.load() == nil)
    }

    private func makeStore() -> (ConnectionSessionsSnapshotStore, UserDefaults) {
        let suiteName = "test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (ConnectionSessionsSnapshotStore(userDefaults: defaults), defaults)
    }
}
