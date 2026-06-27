import Foundation
import Testing

// Test Context:
// These source-boundary tests protect iOS Ghostty surface display ownership.
// The UIKit terminal view may size IOSurface layers and report UI events, but
// Ghostty resize, redraw, external-output, and external-exit C/FFI calls should
// be owned by a focused runtime helper. Update these tests only if those FFI
// responsibilities intentionally move to another non-view owner.

@Suite(.serialized)
struct GhosttyIOSSurfaceDisplayRuntimeBoundaryTests {
    @Test
    func iOSTerminalViewDelegatesSurfaceDisplayFFIToRuntimeOwner() throws {
        let root = try sourceRoot()
        let viewSource = try source(
            at: root.appendingPathComponent("VVTerm/GhosttyTerminal/GhosttyTerminalView+iOS.swift")
        )
        let runtimeSource = try source(
            at: root.appendingPathComponent("VVTerm/GhosttyTerminal/TerminalIOSSurfaceDisplayRuntime.swift")
        )

        // Given the iOS terminal view needs Ghostty resize, redraw, and
        // External backend output lifecycle.
        #expect(viewSource.contains("private let surfaceDisplayRuntime = TerminalIOSSurfaceDisplayRuntime()"))
        #expect(viewSource.contains("surfaceDisplayRuntime.resizeIfNeeded"))
        #expect(viewSource.contains("surfaceDisplayRuntime.forceResize"))
        #expect(viewSource.contains("surfaceDisplayRuntime.redraw"))
        #expect(viewSource.contains("surfaceDisplayRuntime.writeOutput"))
        #expect(viewSource.contains("surfaceDisplayRuntime.externalExited"))

        // Then the main UIKit view does not directly own those C/FFI calls or
        // Ghostty pixel-size tracking state.
        #expect(!viewSource.contains("private var lastPixelSize"))
        #expect(!viewSource.contains("private var lastContentScale"))
        #expect(!viewSource.contains("ghostty_surface_set_content_scale"))
        #expect(!viewSource.contains("ghostty_surface_set_size"))
        #expect(!viewSource.contains("ghostty_surface_refresh"))
        #expect(!viewSource.contains("ghostty_surface_draw"))
        #expect(!viewSource.contains("ghostty_surface_write_output"))
        #expect(!viewSource.contains("ghostty_surface_external_exited"))

        #expect(runtimeSource.contains("final class TerminalIOSSurfaceDisplayRuntime"))
        #expect(runtimeSource.contains("ghostty_surface_set_content_scale"))
        #expect(runtimeSource.contains("ghostty_surface_set_size"))
        #expect(runtimeSource.contains("ghostty_surface_refresh"))
        #expect(runtimeSource.contains("ghostty_surface_draw"))
        #expect(runtimeSource.contains("ghostty_surface_write_output"))
        #expect(runtimeSource.contains("ghostty_surface_external_exited"))
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
