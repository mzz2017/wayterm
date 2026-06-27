import Foundation
import Testing
@testable import VVTerm

// Test Context:
// These tests protect the Servers local persistence service boundary after
// UserDefaults encoding moved out of ServerManager+Persistence. They use
// isolated UserDefaults suites and no CloudKit; update only when the persisted
// local cache keys or bootstrap marker semantics intentionally change.

@Suite(.serialized)
@MainActor
struct ServerLocalDataStoreTests {
    @Test
    func userDefaultsStoreRoundTripsServerWorkspaceAndBootstrapMarkers() throws {
        let defaults = makeDefaults()
        let store = UserDefaultsServerLocalDataStore(defaults: defaults)
        let workspace = Workspace(id: UUID(), name: "Main", order: 0)
        let server = Server(
            id: UUID(),
            workspaceId: workspace.id,
            name: "Shell",
            host: "local-store.example.com",
            username: "root"
        )

        // Given local server data and first-run markers are written through the store.
        store.storeServers([server])
        store.storeWorkspaces([workspace])
        store.didBootstrapDefaultWorkspace = true
        store.pendingBootstrapWorkspaceID = workspace.id
        defaults.set(true, forKey: "hasSeenWelcome")

        // When a fresh store reads the same suite.
        let reloadedStore = UserDefaultsServerLocalDataStore(defaults: defaults)

        // Then the persisted cache and marker values survive without ServerManager decoding them.
        #expect(reloadedStore.loadServers()?.map(\.id) == [server.id])
        #expect(reloadedStore.loadWorkspaces()?.map(\.id) == [workspace.id])
        #expect(reloadedStore.didBootstrapDefaultWorkspace)
        #expect(reloadedStore.hasSeenWelcome)
        #expect(reloadedStore.pendingBootstrapWorkspaceID == workspace.id)
    }

    @Test
    func serverManagerLoadsAndSavesThroughInjectedLocalDataStore() {
        let workspace = Workspace(id: UUID(), name: "Injected", order: 0)
        let server = Server(
            id: UUID(),
            workspaceId: workspace.id,
            name: "Injected Shell",
            host: "injected-store.example.com",
            username: "root"
        )
        let store = InMemoryServerLocalDataStore(
            servers: [server],
            workspaces: [workspace],
            didBootstrapDefaultWorkspace: true
        )
        let manager = ServerManager(
            cloudKit: DisabledServerCloudSyncService(),
            syncCoordinator: NoopServerPendingCloudSyncCoordinator(),
            localDataStore: store,
            loadLocalDataOnInit: true,
            startStartupLoad: false,
            isProProvider: { false }
        )

        // Given the manager was initialized with a local-data service containing cached data.
        #expect(manager.servers.map(\.id) == [server.id])
        #expect(manager.workspaces.map(\.id) == [workspace.id])

        // When local state is saved back through the manager.
        manager.servers = []
        manager.workspaces = []
        manager.saveLocalData()

        // Then persistence writes go through the injected service, not global UserDefaults.
        #expect(store.loadServers()?.isEmpty == true)
        #expect(store.loadWorkspaces()?.isEmpty == true)
    }

    private func makeDefaults(testName: String = #function) -> UserDefaults {
        let suiteName = "ServerLocalDataStoreTests.\(testName).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
