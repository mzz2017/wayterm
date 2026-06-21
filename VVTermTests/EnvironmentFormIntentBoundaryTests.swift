import Foundation
import Testing

// Test Context:
// These tests protect EnvironmentFormSheet's UI/Application boundary for
// user-initiated environment create and update actions. Environment saves
// mutate workspace metadata and can update servers assigned to that
// environment, so the SwiftUI form may validate local draft fields and update
// presentation callbacks, but it must not own the async save task or call
// lower-level workspace/environment CRUD methods directly. Update this context
// only when environment form save ownership intentionally moves to another
// application-layer owner.
@Suite
struct EnvironmentFormIntentBoundaryTests {
    @Test
    func environmentFormSendsSaveIntentToServerManagerRequest() throws {
        // Given the environment form SwiftUI source.
        let root = try sourceRoot()
        let source = try source(
            at: root.appendingPathComponent("VVTerm/Features/Servers/UI/Workspace/EnvironmentFormSheet.swift")
        )

        // Then the form must call a request-style application API instead of
        // owning fire-and-forget async CRUD work.
        #expect(
            !source.contains("Task {"),
            "EnvironmentFormSheet should not own async environment save Task state."
        )
        #expect(
            !source.contains("try await serverManager.updateEnvironment"),
            "EnvironmentFormSheet should call requestEnvironmentSave instead of updateEnvironment directly."
        )
        #expect(
            !source.contains("try await serverManager.updateWorkspace"),
            "EnvironmentFormSheet should call requestEnvironmentSave instead of updateWorkspace directly."
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
