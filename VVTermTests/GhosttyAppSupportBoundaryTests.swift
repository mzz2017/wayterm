import Foundation
import Testing

// Test Context:
// These source-boundary tests protect Ghostty.App superfile control. Ghostty.App
// should own ghostty_app_t startup, cleanup, callbacks, and surface propagation,
// while reusable support values and pure config text generation live in focused
// bridge files. Update only when that ownership intentionally moves again.

@Suite(.serialized)
struct GhosttyAppSupportBoundaryTests {
    @Test
    func appFileDoesNotOwnSupportTypesOrPureConfigBuilder() throws {
        let root = try sourceRoot()
        let appSource = try source(
            at: root.appendingPathComponent("VVTerm/GhosttyTerminal/Bridge/Ghostty.App.swift")
        )
        let configBuilderSource = try source(
            at: root.appendingPathComponent("VVTerm/GhosttyTerminal/Bridge/Ghostty.ConfigBuilder.swift")
        )
        let surfaceReferenceSource = try source(
            at: root.appendingPathComponent("VVTerm/GhosttyTerminal/Bridge/Ghostty.SurfaceReference.swift")
        )

        // Given Ghostty.App is the app lifecycle and callback owner.
        #expect(appSource.contains("class App: ObservableObject"))
        #expect(appSource.contains("ghostty_app_new"))
        #expect(appSource.contains("ghostty_app_free"))

        // Then support types and pure config generation stay in focused files.
        #expect(
            !appSource.contains("enum ConfigBuilder"),
            "Ghostty.App.swift should not own pure Ghostty config text generation."
        )
        #expect(
            !appSource.contains("class SurfaceReference"),
            "Ghostty.App.swift should not own the surface registration reference type."
        )
        #expect(configBuilderSource.contains("enum ConfigBuilder"))
        #expect(configBuilderSource.contains("static func configContent"))
        #expect(surfaceReferenceSource.contains("final class SurfaceReference"))
        #expect(surfaceReferenceSource.contains("func invalidate()"))

        #expect(
            appSource.split(separator: "\n", omittingEmptySubsequences: false).count < 800,
            "Ghostty.App.swift should stay below the AGENTS.md superfile review threshold."
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
