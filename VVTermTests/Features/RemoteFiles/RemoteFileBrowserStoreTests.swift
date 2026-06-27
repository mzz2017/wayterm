import Foundation
import Testing
@testable import VVTerm

// Test Context:
// These tests protect RemoteFiles browser state rules: entry filtering,
// per-tab persistence, and initial path selection. Fakes use in-memory
// UserDefaults suites, so failures usually indicate a browser-state regression
// unless the persisted snapshot model or path-precedence product rule
// intentionally changes.
@MainActor
struct RemoteFileBrowserStoreTests {
    @Test
    func displayedEntriesHideDotFilesAndKeepDirectoryOrdering() {
        let store = RemoteFileBrowserStore(
            persistedStateStore: makeRemoteFileBrowserPersistedStateStore(),
            serverProvider: { _ in nil }
        )
        let tab = makeRemoteFileBrowserTab()

        store.updateState(for: tab) { state in
            state.entries = [
                makeRemoteFileBrowserEntry(name: ".secret", path: "/tmp/.secret", type: .file),
                makeRemoteFileBrowserEntry(name: "docs", path: "/tmp/docs", type: .directory),
                makeRemoteFileBrowserEntry(name: "readme.md", path: "/tmp/readme.md", type: .file)
            ]
            state.showHiddenFiles = false
            state.sort = .name
            state.sortDirection = .ascending
        }

        #expect(store.displayedEntries(for: tab).map(\.name) == ["docs", "readme.md"])
    }

    @Test
    func persistedStateLoadsIntoFreshStoreInstance() {
        let defaults = makeRemoteFileBrowserDefaults()
        let persistedStateStore = makeRemoteFileBrowserPersistedStateStore(defaults: defaults)
        let tab = makeRemoteFileBrowserTab()

        let store = RemoteFileBrowserStore(persistedStateStore: persistedStateStore, serverProvider: { _ in nil })
        store.updateState(for: tab) { state in
            state.currentPath = "/srv/releases"
            state.sort = .size
            state.sortDirection = .ascending
            state.showHiddenFiles = true
            state.hasCustomizedHiddenFiles = true
        }
        store.persistState(for: tab.id)

        let reloadedStore = RemoteFileBrowserStore(persistedStateStore: persistedStateStore, serverProvider: { _ in nil })
        let persisted = reloadedStore.persistedState(for: tab.id)

        #expect(persisted.lastVisitedPath == "/srv/releases")
        #expect(persisted.sort == .size)
        #expect(persisted.sortDirection == .ascending)
        #expect(persisted.showHiddenFiles)
        #expect(persisted.hasCustomizedHiddenFiles)
    }

    @Test
    func legacyServerScopedSnapshotIsDiscardedOnLoad() throws {
        let defaults = makeRemoteFileBrowserDefaults()
        let legacyKey = "remoteFileBrowserState.v1"
        let legacyPayload = try JSONEncoder().encode([
            UUID().uuidString: RemoteFileBrowserPersistedState(lastVisitedPath: "/legacy")
        ])
        defaults.set(legacyPayload, forKey: legacyKey)

        let store = RemoteFileBrowserStore(
            persistedStateStore: makeRemoteFileBrowserPersistedStateStore(defaults: defaults),
            serverProvider: { _ in nil }
        )

        #expect(defaults.object(forKey: legacyKey) == nil)
        #expect(store.persistedStates.isEmpty)
    }

    @Test
    func initialDirectoryCandidatesPreferPersistedPathOverSeedPath() {
        let defaults = makeRemoteFileBrowserDefaults()
        let persistedStateStore = makeRemoteFileBrowserPersistedStateStore(defaults: defaults)
        let server = makeRemoteFileBrowserServer()
        let tab = RemoteFileTab(serverId: server.id, seedPath: "/etc")

        let store = RemoteFileBrowserStore(
            persistedStateStore: persistedStateStore,
            serverProvider: { _ in nil },
            workingDirectoryProvider: { _ in "/srv/app" }
        )
        store.updateState(for: tab) { state in
            state.currentPath = "/etc/nginx"
        }
        store.persistState(for: tab.id)

        let reloadedStore = RemoteFileBrowserStore(
            persistedStateStore: persistedStateStore,
            serverProvider: { _ in nil },
            workingDirectoryProvider: { _ in "/srv/app" }
        )
        let candidates = reloadedStore.initialDirectoryCandidates(
            for: server,
            tab: tab,
            initialPath: tab.seedPath
        )

        #expect(candidates == ["/etc/nginx", "/etc", "/srv/app"])
    }
}
