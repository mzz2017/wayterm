import Foundation
import Testing

// Test Context:
// These source-boundary tests protect iOS Ghostty surface reference ownership.
// GhosttyTerminalView+iOS may route UI events and expose transitional computed
// access for existing extensions, but stored app/surface references should live
// in a dedicated surface owner. Update only when this ownership intentionally
// moves again.

@Suite(.serialized)
struct GhosttyIOSSurfaceOwnerBoundaryTests {
    @Test
    func iOSTerminalViewStoresGhosttyAppAndSurfaceInDedicatedOwner() throws {
        let root = try sourceRoot()
        let viewSource = try source(
            at: root.appendingPathComponent("VVTerm/GhosttyTerminal/iOS/View/GhosttyTerminalView+iOS.swift")
        )
        let surfaceRuntimeSource = try source(
            at: root.appendingPathComponent("VVTerm/GhosttyTerminal/iOS/Surface/GhosttyTerminalView+SurfaceRuntime+iOS.swift")
        )
        let ownerSource = try source(
            at: root.appendingPathComponent("VVTerm/GhosttyTerminal/iOS/Surface/TerminalIOSSurfaceOwner.swift")
        )

        #expect(viewSource.contains("let surfaceOwner: TerminalIOSSurfaceOwner"))
        #expect(viewSource.contains("TerminalIOSSurfaceOwner(ghosttyApp: ghosttyApp, appWrapper: appWrapper)"))
        #expect(viewSource.contains("get { surfaceOwner.surface }"))
        #expect(viewSource.contains("set { surfaceOwner.surface = newValue }"))
        #expect(surfaceRuntimeSource.contains("let app = surfaceOwner.ghosttyApp"))
        #expect(surfaceRuntimeSource.contains("appWrapper: surfaceOwner.appWrapper"))

        #expect(
            !viewSource.contains("var ghosttyApp: ghostty_app_t?"),
            "GhosttyTerminalView+iOS.swift should not store the Ghostty app pointer directly."
        )
        #expect(
            !viewSource.contains("weak var ghosttyAppWrapper"),
            "GhosttyTerminalView+iOS.swift should not store the Ghostty app wrapper directly."
        )
        #expect(
            !viewSource.contains("internal var surface: Ghostty.Surface?"),
            "GhosttyTerminalView+iOS.swift should not store the Ghostty surface directly."
        )

        #expect(ownerSource.contains("final class TerminalIOSSurfaceOwner"))
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
