import Foundation
import Testing

// Test Context:
// These tests protect WorkspaceFormSheet's UI/Application boundary for
// user-initiated workspace save and delete actions. Workspace create/update
// mutate local data and sync state, while workspace delete can also tear down
// live sessions and credentials through contained server deletion. The form may
// update local presentation state in callbacks, but it must not own async CRUD
// tasks or call lower-level workspace CRUD methods directly. Update this
// context only when workspace form save/delete ownership intentionally moves to
// another application-layer owner.
@Suite
struct WorkspaceFormIntentBoundaryTests {
    @Test
    func workspaceFormSendsSaveAndDeleteIntentToServerManagerRequests() throws {
        // Given the workspace form SwiftUI source.
        let root = try sourceRoot()
        let source = try source(
            at: root.appendingPathComponent("VVTerm/Features/Servers/UI/Workspace/WorkspaceFormSheet.swift")
        )

        // Then the form must call request-style application APIs instead of
        // owning fire-and-forget async CRUD tasks.
        #expect(
            !source.contains("Task {"),
            "WorkspaceFormSheet should not own async workspace save/delete Task state."
        )
        #expect(
            !source.contains("try await serverManager.addWorkspace"),
            "WorkspaceFormSheet should call requestWorkspaceSave instead of addWorkspace directly."
        )
        #expect(
            !source.contains("try await serverManager.updateWorkspace"),
            "WorkspaceFormSheet should call requestWorkspaceSave instead of updateWorkspace directly."
        )
        #expect(
            !source.contains("try await serverManager.deleteWorkspace"),
            "WorkspaceFormSheet should call requestWorkspaceDeletion instead of deleteWorkspace directly."
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
