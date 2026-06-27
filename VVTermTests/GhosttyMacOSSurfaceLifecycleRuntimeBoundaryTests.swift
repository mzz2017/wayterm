import Foundation
import Testing

// Test Context:
// These source-boundary tests protect macOS Ghostty surface lifecycle ownership.
// GhosttyTerminalView+macOS may own view wiring, but C surface focus, process
// state, callback invalidation, registration teardown, and free ordering should
// live in a dedicated runtime owner. Update only when this lifecycle ownership
// intentionally moves again.

@Suite(.serialized)
struct GhosttyMacOSSurfaceLifecycleRuntimeBoundaryTests {
    @Test
    func macOSTerminalViewDelegatesSurfaceLifecycleToRuntimeOwner() throws {
        let root = try sourceRoot()
        let viewSource = try source(
            at: root.appendingPathComponent("VVTerm/GhosttyTerminal/macOS/GhosttyTerminalView+macOS.swift")
        )
        let runtimeSource = try source(
            at: root.appendingPathComponent("VVTerm/GhosttyTerminal/macOS/TerminalMacOSSurfaceLifecycleRuntime.swift")
        )

        #expect(viewSource.contains("let surfaceLifecycleRuntime = TerminalMacOSSurfaceLifecycleRuntime()"))
        #expect(viewSource.contains("surfaceLifecycleRuntime.cleanup"))
        #expect(viewSource.contains("surfaceLifecycleRuntime.setFocus"))
        #expect(viewSource.contains("surfaceLifecycleRuntime.processExited"))

        #expect(
            !viewSource.contains("ghostty_surface_set_focus"),
            "GhosttyTerminalView+macOS.swift should not directly own C focus lifecycle."
        )
        #expect(
            !viewSource.contains("ghostty_surface_process_exited"),
            "GhosttyTerminalView+macOS.swift should not directly query C process lifecycle."
        )
        #expect(
            !viewSource.contains("surface?.free()"),
            "GhosttyTerminalView+macOS.swift should not directly free the surface."
        )
        #expect(
            !viewSource.contains("surface?.invalidateCallbackContext()"),
            "GhosttyTerminalView+macOS.swift should not directly invalidate surface callback context."
        )

        #expect(runtimeSource.contains("final class TerminalMacOSSurfaceLifecycleRuntime"))
        #expect(runtimeSource.contains("ghostty_surface_set_focus"))
        #expect(runtimeSource.contains("ghostty_surface_process_exited"))
        #expect(runtimeSource.contains("surface?.free()"))
        #expect(runtimeSource.contains("surfaceRegistration.unregister()"))
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
