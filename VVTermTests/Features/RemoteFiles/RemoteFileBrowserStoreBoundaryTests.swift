import Foundation
import Testing

// Test Context:
// These source-boundary tests protect RemoteFileBrowserStore superfile control.
// The store owns shared state and dependency composition, while directory
// loading and snapshot application live in a focused Application extension.
// Update only when that ownership boundary intentionally changes.
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
