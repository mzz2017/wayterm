import Foundation
import Testing

// Test Context:
// These source-boundary tests protect macOS Ghostty surface ownership. NSView may
// route AppKit events and expose transitional computed access for existing
// helpers, but stored app/surface references and selected display/custom-IO C/FFI
// operations should live behind TerminalMacOSSurfaceOwner. Update only when this
// ownership intentionally moves again.

@Suite(.serialized)
struct GhosttyMacOSSurfaceOwnerBoundaryTests {
    @Test
    func macOSTerminalViewStoresGhosttyAppAndSurfaceInDedicatedOwner() throws {
        let root = try sourceRoot()
        let viewSource = try source(
            at: root.appendingPathComponent("VVTerm/GhosttyTerminal/macOS/GhosttyTerminalView+macOS.swift")
        )
        let ownerSource = try source(
            at: root.appendingPathComponent("VVTerm/GhosttyTerminal/macOS/TerminalMacOSSurfaceOwner.swift")
        )

        #expect(viewSource.contains("let surfaceOwner: TerminalMacOSSurfaceOwner"))
        #expect(viewSource.contains("TerminalMacOSSurfaceOwner(ghosttyApp: ghosttyApp, appWrapper: appWrapper)"))
        #expect(viewSource.contains("get { surfaceOwner.surface }"))
        #expect(viewSource.contains("set { surfaceOwner.surface = newValue }"))
        #expect(viewSource.contains("let app = surfaceOwner.ghosttyApp"))
        #expect(ownerSource.contains("appWrapper?.appTick()"))
        #expect(viewSource.contains("appWrapper: surfaceOwner.appWrapper"))

        #expect(
            !viewSource.contains("private var ghosttyApp: ghostty_app_t?"),
            "GhosttyTerminalView+macOS.swift should not store the Ghostty app pointer directly."
        )
        #expect(
            !viewSource.contains("private weak var ghosttyAppWrapper"),
            "GhosttyTerminalView+macOS.swift should not store the Ghostty app wrapper directly."
        )
        #expect(
            !viewSource.contains("internal var surface: Ghostty.Surface?"),
            "GhosttyTerminalView+macOS.swift should not store the Ghostty surface directly."
        )

        #expect(ownerSource.contains("final class TerminalMacOSSurfaceOwner"))
        #expect(ownerSource.contains("let ghosttyApp: ghostty_app_t"))
        #expect(ownerSource.contains("weak var appWrapper: Ghostty.App?"))
        #expect(ownerSource.contains("var surface: Ghostty.Surface?"))
        #expect(ownerSource.contains("func tickDisplayLink("))
        #expect(ownerSource.contains("func hasSelection() -> Bool"))
        #expect(ownerSource.contains("func forceRefresh("))
        #expect(ownerSource.contains("func updateSurfaceConfig("))
        #expect(ownerSource.contains("func writeOutput("))
        #expect(ownerSource.contains("func externalExited("))
        #expect(ownerSource.contains("ghostty_surface_set_size("))
        #expect(ownerSource.contains("ghostty_surface_refresh("))
        #expect(ownerSource.contains("ghostty_surface_draw("))
        #expect(ownerSource.contains("ghostty_surface_write_output("))
        #expect(ownerSource.contains("ghostty_surface_external_exited("))
        #expect(ownerSource.contains("ghostty_surface_has_selection("))

        #expect(
            !viewSource.contains("ghostty_surface_set_size("),
            "GhosttyTerminalView+macOS.swift should route surface resize refresh through the surface owner."
        )
        #expect(
            !viewSource.contains("ghostty_surface_refresh("),
            "GhosttyTerminalView+macOS.swift should route surface refresh through the surface owner."
        )
        #expect(
            !viewSource.contains("ghostty_surface_draw("),
            "GhosttyTerminalView+macOS.swift should route surface drawing through the surface owner."
        )
        #expect(
            !viewSource.contains("ghostty_surface_write_output("),
            "GhosttyTerminalView+macOS.swift should route custom IO writes through the surface owner."
        )
        #expect(
            !viewSource.contains("ghostty_surface_external_exited("),
            "GhosttyTerminalView+macOS.swift should route process-exit notifications through the surface owner."
        )
        #expect(
            !viewSource.contains("ghostty_surface_has_selection("),
            "GhosttyTerminalView+macOS.swift should route selection checks through the surface owner."
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
