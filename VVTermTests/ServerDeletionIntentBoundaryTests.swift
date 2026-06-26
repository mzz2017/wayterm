import Foundation
import Testing

// Test Context:
// These tests protect user-initiated server/workspace/environment deletion
// ownership at the UI/Application boundary. Server, workspace, and environment
// delete operations mutate local data and sync state, and some paths also tear
// down live runtime state, credentials, and known hosts, so UI files must send
// intent to the application-layer deletion request API instead of launching
// untracked tasks that swallow errors with try?. The tests inspect source
// placement only; update them only when destructive delete intent ownership
// intentionally moves to a different application-layer owner.
@Suite
struct ServerDeletionIntentBoundaryTests {
    @Test
    func destructiveDeletionUIUsesApplicationIntentRequests() throws {
        // Given server, workspace, and environment deletion entry points in
        // shared, macOS, and iOS UI.
        let root = try sourceRoot()
        let sources = try [
            "VVTerm/Core/UI/SidebarComponents.swift",
            "VVTerm/Features/Servers/UI/iOS/iOSServerComponents.swift",
            "VVTerm/Features/Servers/UI/iOS/iOSServerListView.swift",
            "VVTerm/Features/Servers/UI/Workspace/WorkspaceSwitcherSheet.swift",
            "VVTerm/Features/Servers/UI/Sidebar/ServerSidebarView.swift"
        ].map { path in
            try source(at: root.appendingPathComponent(path))
        }.joined(separator: "\n")

        // Then UI must not drop deletion errors by calling async delete methods
        // inside fire-and-forget try? tasks.
        #expect(
            !sources.contains("try? await ServerManager.shared.deleteServer"),
            "Server row deletion should call ServerManager.requestServerDeletion instead of swallowing deleteServer failures."
        )
        #expect(
            !sources.contains("try? await serverManager.deleteWorkspace"),
            "Workspace deletion UI should call ServerManager.requestWorkspaceDeletion instead of swallowing deleteWorkspace failures."
        )
        #expect(
            !sources.contains("try? await serverManager.deleteEnvironment"),
            "Environment deletion UI should call ServerManager.requestEnvironmentDeletion instead of swallowing deleteEnvironment failures."
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
