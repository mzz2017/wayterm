import Foundation
import Testing

// Test Context:
// Core/UI empty states are shared presentation primitives. Feature or app
// boundaries should adapt Server domain models into display text before composing
// these views. Update this test only if Core/UI intentionally becomes a
// feature-aware presentation layer again.
@Suite
struct CoreUIEmptyStateBoundaryTests {
    @Test
    func coreEmptyStatesReceiveDisplayTextInsteadOfServerDomainModels() throws {
        let root = try sourceRoot()
        let emptyStateSource = try source(
            at: root.appendingPathComponent("VVTerm/Core/UI/EmptyStateViews.swift")
        )
        let contentViewSource = try source(
            at: root.appendingPathComponent("VVTerm/App/ContentView.swift")
        )

        // Given Core/UI owns reusable empty-state presentation.
        #expect(
            emptyStateSource.contains("struct ServerConnectEmptyState"),
            "Core/UI should keep the reusable server-connect empty state view."
        )

        // When the selected server is adapted for presentation.
        #expect(
            !emptyStateSource.contains("let server: Server"),
            "Core/UI empty states should not store Servers feature domain models."
        )
        #expect(
            !emptyStateSource.contains("server.visibleAddress"),
            "Core/UI empty states should not apply Servers privacy display policy directly."
        )

        // Then the app composition boundary provides display text to Core/UI.
        #expect(
            contentViewSource.contains("serverName: server.name"),
            "ContentView should adapt the selected server name before composing Core/UI empty states."
        )
        #expect(
            contentViewSource.contains("serverAddress: server.visibleAddress"),
            "ContentView should adapt the selected server address before composing Core/UI empty states."
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
