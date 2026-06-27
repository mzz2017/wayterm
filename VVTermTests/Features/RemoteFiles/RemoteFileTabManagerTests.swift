import Foundation
import Testing
@testable import VVTerm

// Test Context:
// These tests protect RemoteFiles tab creation, selection, close behavior, and
// snapshot persistence. They use isolated UserDefaults suites and no network
// I/O; update only when file-tab workflow semantics intentionally change.

@MainActor
struct RemoteFileTabManagerTests {
    @Test
    func closingLastTabPreservesExplicitEmptyState() {
        let manager = RemoteFileTabManager(snapshotStore: makeStore(), isProProvider: { false })
        let server = makeServer()

        let initialTab = manager.ensureInitialTab(for: server, seedPath: "/srv")!
        let removedTab = manager.closeTab(initialTab)

        #expect(removedTab == initialTab)
        #expect(manager.tabs(for: server.id).isEmpty)
        #expect(manager.hasInitializedTabs(for: server.id))
        #expect(manager.ensureInitialTab(for: server, seedPath: "/srv") == nil)
    }

    @Test
    func closingSelectedTabPrefersRightNeighborThenLeftNeighbor() throws {
        let server = makeServer()
        let firstTab = RemoteFileTab(serverId: server.id, seedPath: "/etc")
        let secondTab = RemoteFileTab(serverId: server.id, seedPath: "/var/log")
        let thirdTab = RemoteFileTab(serverId: server.id, seedPath: "/srv/app")
        let store = makeStore()
        let snapshot = RemoteFileTabSnapshot(
            tabsByServer: [server.id.uuidString: [firstTab, secondTab, thirdTab]],
            selectedTabByServer: [server.id.uuidString: secondTab.id]
        )
        try store.save(snapshot)

        let manager = RemoteFileTabManager(snapshotStore: store, isProProvider: { false })
        let removedMiddle = manager.closeTab(secondTab)

        #expect(removedMiddle == secondTab)
        #expect(manager.selectedTab(for: server.id)?.id == thirdTab.id)

        let removedRightmost = manager.closeTab(thirdTab)

        #expect(removedRightmost == thirdTab)
        #expect(manager.selectedTab(for: server.id)?.id == firstTab.id)
    }

    @Test
    func freeTierRejectsFileTabAfterLimit() {
        let manager = RemoteFileTabManager(snapshotStore: makeStore(), isProProvider: { false })
        let server = makeServer()

        // Given a free user has reached the RemoteFiles tab limit.
        for _ in 0..<FreeTierLimits.maxFileTabs {
            #expect(manager.openTab(for: server) != nil)
        }

        // Then the next tab request is rejected without consulting StoreManager.
        #expect(manager.openTab(for: server) == nil)
        #expect(manager.tabs(for: server.id).count == FreeTierLimits.maxFileTabs)
    }

    @Test
    func proProviderAllowsFileTabsPastFreeLimit() {
        let manager = RemoteFileTabManager(snapshotStore: makeStore(), isProProvider: { true })
        let server = makeServer()

        // Given App composition reports an active Pro entitlement.
        for _ in 0...FreeTierLimits.maxFileTabs {
            #expect(manager.openTab(for: server) != nil)
        }

        // Then RemoteFiles applies the injected policy instead of reading the
        // Store feature singleton directly.
        #expect(manager.tabs(for: server.id).count == FreeTierLimits.maxFileTabs + 1)
    }

    @Test
    func persistedTabsRestoreIntoFreshManager() {
        let store = makeStore()
        let server = makeServer()
        let manager = RemoteFileTabManager(snapshotStore: store, isProProvider: { true })

        // Given tab state is mutated through the application-layer manager.
        let firstTab = manager.openTab(for: server, seedPath: "/etc")!
        let secondTab = manager.openTab(for: server, seedPath: "/srv")!
        manager.selectTab(firstTab)
        manager.updateLastKnownPath("/srv/current", for: secondTab.id)

        // When a fresh manager restores from the same infrastructure store.
        let restoredManager = RemoteFileTabManager(snapshotStore: store, isProProvider: { true })

        // Then persisted tab order, selected tab, and per-tab path state survive.
        #expect(restoredManager.tabs(for: server.id).map(\.id) == [firstTab.id, secondTab.id])
        #expect(restoredManager.selectedTab(for: server.id)?.id == firstTab.id)
        #expect(restoredManager.tabs(for: server.id).last?.lastKnownPath == "/srv/current")
    }

    private func makeServer() -> Server {
        Server(
            workspaceId: UUID(),
            name: "Production",
            host: "example.com",
            username: "root"
        )
    }

    private func makeStore() -> RemoteFileTabsSnapshotStore {
        let suiteName = "RemoteFileTabManagerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return RemoteFileTabsSnapshotStore(userDefaults: defaults)
    }
}
