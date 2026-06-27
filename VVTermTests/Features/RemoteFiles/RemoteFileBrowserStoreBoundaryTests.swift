import Foundation
import Testing

// Test Context:
// These source-boundary tests protect RemoteFileBrowserStore superfile control.
// The store owns shared state and dependency composition, while directory
// loading, snapshot application, and infrastructure persistence live in focused
// owned files. Update only when that ownership boundary intentionally changes.
struct RemoteFileBrowserStoreBoundaryTests {
    @Test
    func browserStoreMainFileDoesNotOwnDirectoryLoadingImplementation() throws {
        let root = try sourceRoot()
        let storeSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/RemoteFiles/Application/RemoteFileBrowserStore.swift")
        )
        let directorySource = try source(
            at: root.appendingPathComponent("VVTerm/Features/RemoteFiles/Application/RemoteFileBrowserStore+DirectoryLoading.swift")
        )
        let navigationSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/RemoteFiles/Application/RemoteFileNavigationCoordinator.swift")
        )

        for implementationSymbol in [
            "func loadInitialPath(",
            "func loadDirectory(path:",
            "func resolveInitialDirectorySnapshot(",
            "private func directorySnapshot(",
            "func applyDirectorySnapshot("
        ] {
            #expect(
                !storeSource.contains(implementationSymbol),
                "RemoteFileBrowserStore.swift should not own directory loading implementation \(implementationSymbol)."
            )
            #expect(
                directorySource.contains(implementationSymbol),
                "RemoteFileBrowserStore+DirectoryLoading.swift should own \(implementationSymbol)."
            )
        }

        #expect(
            navigationSource.contains("func requestNavigation("),
            "RemoteFileNavigationCoordinator.swift should keep UI navigation intent task ownership."
        )
        #expect(
            !storeSource.contains("func requestNavigation("),
            "RemoteFileBrowserStore.swift should not own navigation request task orchestration."
        )
    }

    @Test
    func tabManagerUsesSnapshotStoreForPersistenceCodec() throws {
        let root = try sourceRoot()
        let managerSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/RemoteFiles/Application/RemoteFileTabManager.swift")
        )
        let storeSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/RemoteFiles/Infrastructure/RemoteFileTabsSnapshotStore.swift")
        )

        // Given RemoteFiles tab state is durable UI state, but encoding and
        // storage-key ownership should stay behind dedicated infrastructure.
        #expect(managerSource.contains("RemoteFileTabsSnapshotStore"))
        #expect(managerSource.contains("snapshotStore.save(snapshot)"))
        #expect(managerSource.contains("snapshotStore.load()"))
        #expect(storeSource.contains("struct RemoteFileTabsSnapshotStore"))
        #expect(storeSource.contains("func save(_ snapshot: RemoteFileTabSnapshot) throws"))
        #expect(storeSource.contains("func load() throws -> RemoteFileTabSnapshot?"))

        // Then RemoteFileTabManager keeps tab policy and restoration filtering,
        // but does not own UserDefaults or JSON codec details directly.
        #expect(!managerSource.contains("UserDefaults"))
        #expect(!managerSource.contains("JSONEncoder()"))
        #expect(!managerSource.contains("JSONDecoder()"))
    }

    @Test
    func browserStoreUsesInfrastructureForPersistedStateCodec() throws {
        let root = try sourceRoot()
        let storeSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/RemoteFiles/Application/RemoteFileBrowserStore.swift")
        )
        let persistenceSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/RemoteFiles/Application/RemoteFilePersistence.swift")
        )
        let persistedStateStoreSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/RemoteFiles/Infrastructure/RemoteFileBrowserPersistedStateStore.swift")
        )

        // Given browser state persistence is durable feature infrastructure,
        // RemoteFileBrowserStore may request load/save but should not own the codec.
        #expect(storeSource.contains("RemoteFileBrowserPersistedStateStore"))
        #expect(persistenceSource.contains("persistedStateStore.load()"))
        #expect(persistenceSource.contains("persistedStateStore.save(persistedStates)"))
        #expect(persistedStateStoreSource.contains("struct RemoteFileBrowserPersistedStateStore"))
        #expect(persistedStateStoreSource.contains("func load() throws -> [String: RemoteFileBrowserPersistedState]"))
        #expect(persistedStateStoreSource.contains("func save(_ states: [String: RemoteFileBrowserPersistedState]) throws"))

        // Then UserDefaults keys and JSON codec details stay out of the
        // application-layer browser state owner.
        #expect(!storeSource.contains("UserDefaults"))
        #expect(!storeSource.contains("JSONEncoder()"))
        #expect(!storeSource.contains("JSONDecoder()"))
        #expect(!persistenceSource.contains("UserDefaults"))
        #expect(!persistenceSource.contains("JSONEncoder()"))
        #expect(!persistenceSource.contains("JSONDecoder()"))
    }

    private func source(at url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    private func sourceRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.lastPathComponent != "VVTermTests" {
            let next = url.deletingLastPathComponent()
            if next.path == url.path {
                throw SourceRootError.notFound
            }
            url = next
        }
        return url.deletingLastPathComponent()
    }

    private enum SourceRootError: Error {
        case notFound
    }
}
