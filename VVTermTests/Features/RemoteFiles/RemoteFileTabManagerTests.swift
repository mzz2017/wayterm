import Foundation
import Testing
@testable import VVTerm

// Test Context:
// These tests protect RemoteFiles tab creation, selection, and close behavior.
// They use in-memory tab state and no network I/O; update only when file-tab
// workflow semantics intentionally change.

@MainActor
struct RemoteFileTabManagerTests {
    @Test
    func closingLastTabPreservesExplicitEmptyState() {
        let defaults = makeDefaults()
        let manager = RemoteFileTabManager(defaults: defaults, isProProvider: { false })
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
        let defaults = makeDefaults()
        let server = makeServer()
        let firstTab = RemoteFileTab(serverId: server.id, seedPath: "/etc")
        let secondTab = RemoteFileTab(serverId: server.id, seedPath: "/var/log")
        let thirdTab = RemoteFileTab(serverId: server.id, seedPath: "/srv/app")
        let snapshot = RemoteFileTabSnapshot(
            tabsByServer: [server.id.uuidString: [firstTab, secondTab, thirdTab]],
            selectedTabByServer: [server.id.uuidString: secondTab.id]
        )
        defaults.set(try JSONEncoder().encode(snapshot), forKey: "remoteFileTabsSnapshot.v1")

        let manager = RemoteFileTabManager(defaults: defaults, isProProvider: { false })
        let removedMiddle = manager.closeTab(secondTab)

        #expect(removedMiddle == secondTab)
        #expect(manager.selectedTab(for: server.id)?.id == thirdTab.id)

        let removedRightmost = manager.closeTab(thirdTab)

        #expect(removedRightmost == thirdTab)
        #expect(manager.selectedTab(for: server.id)?.id == firstTab.id)
    }

    @Test
    func freeTierRejectsFileTabAfterLimit() {
        let manager = RemoteFileTabManager(defaults: makeDefaults(), isProProvider: { false })
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
        let manager = RemoteFileTabManager(defaults: makeDefaults(), isProProvider: { true })
        let server = makeServer()

        // Given App composition reports an active Pro entitlement.
        for _ in 0...FreeTierLimits.maxFileTabs {
            #expect(manager.openTab(for: server) != nil)
        }

        // Then RemoteFiles applies the injected policy instead of reading the
        // Store feature singleton directly.
        #expect(manager.tabs(for: server.id).count == FreeTierLimits.maxFileTabs + 1)
    }

    private func makeServer() -> Server {
        Server(
            workspaceId: UUID(),
            name: "Production",
            host: "example.com",
            username: "root"
        )
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "RemoteFileTabManagerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
