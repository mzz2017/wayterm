import Foundation
import Testing
@testable import Waterm

// Test Context:
// These tests protect terminal tab snapshot persistence after storage encoding
// moved out of TerminalTabManager. They use isolated UserDefaults suites and no
// live terminal runtime; update only when the snapshot persistence contract or
// storage key injection behavior intentionally changes.

struct TerminalTabsSnapshotStoreTests {
    @Test
    func saveThenLoadRoundTripsSnapshot() throws {
        let (store, defaults) = makeStore()
        let serverId = UUID()
        let tabId = UUID()
        let paneId = UUID()
        let createdAt = Date(timeIntervalSince1970: 1_234)
        let tab = TerminalTab(
            id: tabId,
            serverId: serverId,
            title: "Main",
            createdAt: createdAt,
            rootPaneId: paneId,
            focusedPaneId: paneId,
            layout: nil
        )

        let snapshot = TerminalTabsSnapshot(
            servers: [
                .init(
                    serverId: serverId,
                    tabs: [
                        .init(from: tab, paneStates: [:])
                    ],
                    selectedTabId: tabId,
                    selectedView: "terminal"
                )
            ]
        )

        // When the store saves and reloads a snapshot.
        try store.save(snapshot)
        let loaded = try #require(try store.load())

        // Then the persisted tab shape round-trips through UserDefaults.
        #expect(defaults.data(forKey: "terminalTabsSnapshot.v1") != nil)
        #expect(loaded.servers.first?.serverId == serverId)
        #expect(loaded.servers.first?.tabs.first?.id == tabId)
        #expect(loaded.servers.first?.tabs.first?.title == "Main")
        #expect(loaded.servers.first?.selectedView == "terminal")
    }

    @Test
    func removeClearsStoredSnapshot() throws {
        let (store, defaults) = makeStore()
        let snapshot = TerminalTabsSnapshot(servers: [])

        // Given a persisted snapshot exists.
        try store.save(snapshot)
        #expect(defaults.data(forKey: "terminalTabsSnapshot.v1") != nil)

        // When the store removes it.
        store.remove()

        // Then future loads report no snapshot.
        #expect(defaults.data(forKey: "terminalTabsSnapshot.v1") == nil)
        #expect(try store.load() == nil)
    }

    private func makeStore() -> (TerminalTabsSnapshotStore, UserDefaults) {
        let suiteName = "test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (TerminalTabsSnapshotStore(userDefaults: defaults), defaults)
    }
}
