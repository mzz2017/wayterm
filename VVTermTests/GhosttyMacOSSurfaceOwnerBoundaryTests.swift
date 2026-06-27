import Foundation
import Testing

// Test Context:
// These source-boundary tests protect macOS Ghostty surface reference ownership.
// GhosttyTerminalView+macOS may route AppKit events and expose transitional
// computed access for existing helpers, but stored app/surface references should
// live in a dedicated surface owner. Update only when this ownership
// intentionally moves again.

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
        #expect(viewSource.contains("surfaceOwner.appWrapper?.appTick()"))
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
