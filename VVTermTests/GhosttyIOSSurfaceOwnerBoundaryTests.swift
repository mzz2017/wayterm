import Foundation
import Testing

// Test Context:
// These source-boundary tests protect iOS Ghostty surface ownership. UIView may
// route UI events and expose transitional computed access for existing
// extensions, but stored app/surface references, direct surface actions, and
// selected display C/FFI operations should live behind TerminalIOSSurfaceOwner.
// Update only when this ownership intentionally moves again.

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
        let scrollGestureSource = try source(
            at: root.appendingPathComponent("VVTerm/GhosttyTerminal/iOS/Scroll/GhosttyTerminalView+ScrollGesture+iOS.swift")
        )
        let nativeScrollSource = try source(
            at: root.appendingPathComponent("VVTerm/GhosttyTerminal/iOS/Scroll/TerminalNativeScrollContainerView+iOS.swift")
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
        #expect(ownerSource.contains("var hasLiveSurface: Bool"))
        #expect(ownerSource.contains("var isMouseCaptured: Bool"))
        #expect(ownerSource.contains("var isInAlternateScreen: Bool"))
        #expect(ownerSource.contains("func resizeIfNeeded("))
        #expect(ownerSource.contains("func forceResize("))
        #expect(ownerSource.contains("func redraw("))
        #expect(ownerSource.contains("func setColorScheme("))
        #expect(ownerSource.contains("func updateSurfaceConfig("))
        #expect(ownerSource.contains("func writeOutput("))
        #expect(ownerSource.contains("func externalExited("))
        #expect(ownerSource.contains("func sendMousePosition("))
        #expect(ownerSource.contains("func sendMouseScroll("))

        #expect(scrollGestureSource.contains("surfaceOwner.isMouseCaptured"))
        #expect(scrollGestureSource.contains("surfaceOwner.isInAlternateScreen"))
        #expect(scrollGestureSource.contains("surfaceOwner.hasLiveSurface"))
        #expect(scrollGestureSource.contains("surfaceOwner.sendMousePosition(position)"))
        #expect(scrollGestureSource.contains("surfaceOwner.sendMouseScroll(event)"))
        #expect(nativeScrollSource.contains("terminalView.surfaceOwner.perform(action: \"scroll_to_row:\\(row)\")"))

        #expect(
            !viewSource.contains("surface?.unsafeCValue != nil"),
            "GhosttyTerminalView+iOS.swift should ask the surface owner whether a live surface exists."
        )
        #expect(
            !viewSource.contains("surfaceDisplayRuntime.resizeIfNeeded(surface:"),
            "GhosttyTerminalView+iOS.swift should not pass raw surface handles into display resizing."
        )
        #expect(
            !viewSource.contains("surfaceDisplayRuntime.setColorScheme("),
            "GhosttyTerminalView+iOS.swift should not pass raw surface handles into color-scheme updates."
        )
        #expect(
            !viewSource.contains("surfaceOwner.appWrapper?.updateSurfaceConfig("),
            "GhosttyTerminalView+iOS.swift should route surface config updates through the surface owner."
        )
        #expect(
            !surfaceRuntimeSource.contains("surfaceDisplayRuntime.forceResize(surface:"),
            "GhosttyTerminalView+SurfaceRuntime+iOS.swift should not pass raw surface handles into forced resizing."
        )
        #expect(
            !surfaceRuntimeSource.contains("surfaceDisplayRuntime.writeOutput("),
            "GhosttyTerminalView+SurfaceRuntime+iOS.swift should route custom IO writes through the surface owner."
        )
        #expect(
            !surfaceRuntimeSource.contains("surfaceDisplayRuntime.externalExited("),
            "GhosttyTerminalView+SurfaceRuntime+iOS.swift should route process-exit notifications through the surface owner."
        )
        #expect(
            !scrollGestureSource.contains("surface?.mouseCaptured"),
            "GhosttyTerminalView+ScrollGesture+iOS.swift should route scroll-owner state through the surface owner."
        )
        #expect(
            !scrollGestureSource.contains("surface?.inAlternateScreen"),
            "GhosttyTerminalView+ScrollGesture+iOS.swift should route alternate-screen state through the surface owner."
        )
        #expect(
            !scrollGestureSource.contains("surface?.sendMousePos"),
            "GhosttyTerminalView+ScrollGesture+iOS.swift should route mouse position events through the surface owner."
        )
        #expect(
            !scrollGestureSource.contains("surface?.sendMouseScroll"),
            "GhosttyTerminalView+ScrollGesture+iOS.swift should route mouse scroll events through the surface owner."
        )
        #expect(
            !nativeScrollSource.contains("terminalView.surface?.perform"),
            "TerminalNativeScrollContainerView+iOS.swift should route surface actions through the surface owner."
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
