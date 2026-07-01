import Foundation
import Testing

// Test Context:
// These source-boundary tests protect iOS Ghostty surface ownership. UIView may
// route UI events and expose transitional computed access for existing
// extensions, but stored app/surface references, direct lifecycle handoff,
// direct surface actions, and selected display C/FFI operations should live behind TerminalIOSSurfaceOwner.
// Update only when this ownership intentionally moves again.

@Suite(.serialized)
struct GhosttyIOSSurfaceOwnerBoundaryTests {
    @Test
    func iOSTerminalViewStoresGhosttyAppAndSurfaceInDedicatedOwner() throws {
        let root = try sourceRoot()
        let viewSource = try source(
            at: root.appendingPathComponent("Waterm/GhosttyTerminal/iOS/View/GhosttyTerminalView+iOS.swift")
        )
        let surfaceRuntimeSource = try source(
            at: root.appendingPathComponent("Waterm/GhosttyTerminal/iOS/Surface/GhosttyTerminalView+SurfaceRuntime+iOS.swift")
        )
        let ownerSource = try source(
            at: root.appendingPathComponent("Waterm/GhosttyTerminal/iOS/Surface/TerminalIOSSurfaceOwner.swift")
        )
        let appSource = try source(
            at: root.appendingPathComponent("Waterm/GhosttyTerminal/Bridge/Ghostty.App.swift")
        )
        let appClipboardSource = try source(
            at: root.appendingPathComponent("Waterm/GhosttyTerminal/Bridge/Ghostty.App+Clipboard.swift")
        )
        let scrollGestureSource = try source(
            at: root.appendingPathComponent("Waterm/GhosttyTerminal/iOS/Scroll/GhosttyTerminalView+ScrollGesture+iOS.swift")
        )
        let nativeScrollSource = try source(
            at: root.appendingPathComponent("Waterm/GhosttyTerminal/iOS/Scroll/TerminalNativeScrollContainerView+iOS.swift")
        )
        let findSource = try source(
            at: root.appendingPathComponent("Waterm/GhosttyTerminal/iOS/Find/GhosttyTerminalView+FindNavigator+iOS.swift")
        )
        let imeProxySource = try source(
            at: root.appendingPathComponent("Waterm/GhosttyTerminal/iOS/Input/GhosttyTerminalView+IMEProxy+iOS.swift")
        )

        #expect(viewSource.contains("let surfaceOwner: TerminalIOSSurfaceOwner"))
        #expect(viewSource.contains("TerminalIOSSurfaceOwner(ghosttyApp: ghosttyApp, appWrapper: appWrapper)"))
        #expect(surfaceRuntimeSource.contains("surfaceOwner.createAndRegisterSurface("))
        #expect(ownerSource.contains("func createAndRegisterSurface("))
        #expect(ownerSource.contains("ghosttyApp: ghosttyApp"))
        #expect(ownerSource.contains("appWrapper: appWrapper"))
        #expect(ownerSource.contains("var liveSurfaceHandle: ghostty_surface_t?"))
        #expect(appClipboardSource.contains("terminalView.surfaceOwner.liveSurfaceHandle"))

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
        #expect(
            !viewSource.contains("var surface: Ghostty.Surface?"),
            "GhosttyTerminalView+iOS.swift should not expose the owned Ghostty surface wrapper."
        )
        #expect(
            !appSource.contains("terminalView.surface?.unsafeCValue")
                && !appClipboardSource.contains("terminalView.surface?.unsafeCValue"),
            "Ghostty.App callbacks should ask the owner for a narrow live surface handle instead of reading the view surface."
        )

        #expect(ownerSource.contains("final class TerminalIOSSurfaceOwner"))
        #expect(ownerSource.contains("let ghosttyApp: ghostty_app_t"))
        #expect(ownerSource.contains("weak var appWrapper: Ghostty.App?"))
        #expect(ownerSource.contains("private var surface: Ghostty.Surface?"))
        #expect(ownerSource.contains("var hasLiveSurface: Bool"))
        #expect(ownerSource.contains("var isMouseCaptured: Bool"))
        #expect(ownerSource.contains("var isInAlternateScreen: Bool"))
        #expect(ownerSource.contains("func cleanup("))
        #expect(ownerSource.contains("func pauseRendering("))
        #expect(ownerSource.contains("func resumeRendering("))
        #expect(ownerSource.contains("func setFocus("))
        #expect(ownerSource.contains("func setOcclusion("))
        #expect(ownerSource.contains("func processExited("))
        #expect(ownerSource.contains("var needsConfirmQuit: Bool"))
        #expect(ownerSource.contains("func terminalSize()"))
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
        #expect(viewSource.contains("surfaceOwner.setFocus(result || super.isFirstResponder)"))
        #expect(viewSource.contains("surfaceOwner.setFocus(false)"))
        #expect(viewSource.contains("surfaceOwner.setOcclusion(isVisible)"))
        #expect(surfaceRuntimeSource.contains("surfaceOwner.cleanup("))
        #expect(surfaceRuntimeSource.contains("surfaceOwner.pauseRendering()"))
        #expect(surfaceRuntimeSource.contains("surfaceOwner.resumeRendering"))
        #expect(surfaceRuntimeSource.contains("surfaceOwner.processExited()"))
        #expect(surfaceRuntimeSource.contains("surfaceOwner.needsConfirmQuit"))
        #expect(surfaceRuntimeSource.contains("surfaceOwner.terminalSize()"))
        #expect(surfaceRuntimeSource.contains("surfaceOwner.perform(action: \"reset\")"))
        #expect(findSource.contains("surfaceOwner.setFocus(false)"))
        #expect(findSource.contains("surfaceOwner.perform(action: action)"))
        #expect(findSource.contains("surfaceOwner.perform(action: \"end_search\")"))
        #expect(imeProxySource.contains("surfaceOwner.setFocus(isFocused)"))

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
            !surfaceRuntimeSource.contains("surfaceOwner.ghosttyApp"),
            "GhosttyTerminalView+SurfaceRuntime+iOS.swift should not read the Ghostty app pointer directly."
        )
        #expect(
            !surfaceRuntimeSource.contains("surfaceOwner.appWrapper"),
            "GhosttyTerminalView+SurfaceRuntime+iOS.swift should not read the Ghostty app wrapper directly."
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
            !viewSource.contains("surfaceLifecycleRuntime.setFocus("),
            "GhosttyTerminalView+iOS.swift should route focus changes through the surface owner."
        )
        #expect(
            !viewSource.contains("surfaceLifecycleRuntime.setOcclusion("),
            "GhosttyTerminalView+iOS.swift should route occlusion changes through the surface owner."
        )
        #expect(
            !surfaceRuntimeSource.contains("surfaceLifecycleRuntime.cleanup("),
            "GhosttyTerminalView+SurfaceRuntime+iOS.swift should route cleanup through the surface owner."
        )
        #expect(
            !surfaceRuntimeSource.contains("surfaceLifecycleRuntime.pauseRendering("),
            "GhosttyTerminalView+SurfaceRuntime+iOS.swift should route pause through the surface owner."
        )
        #expect(
            !surfaceRuntimeSource.contains("surfaceLifecycleRuntime.resumeRendering("),
            "GhosttyTerminalView+SurfaceRuntime+iOS.swift should route resume through the surface owner."
        )
        #expect(
            !surfaceRuntimeSource.contains("surfaceLifecycleRuntime.processExited("),
            "GhosttyTerminalView+SurfaceRuntime+iOS.swift should route process state through the surface owner."
        )
        #expect(
            !surfaceRuntimeSource.contains("surface?.perform(action: \"reset\")"),
            "GhosttyTerminalView+SurfaceRuntime+iOS.swift should route reset through the surface owner."
        )
        #expect(
            !surfaceRuntimeSource.contains("guard let surface else"),
            "GhosttyTerminalView+SurfaceRuntime+iOS.swift should not unwrap the surface for lifecycle state."
        )
        #expect(
            !surfaceRuntimeSource.contains("Ghostty.Surface("),
            "GhosttyTerminalView+SurfaceRuntime+iOS.swift should not create the owned surface wrapper directly."
        )
        #expect(
            !surfaceRuntimeSource.contains("surfaceRegistration.register("),
            "GhosttyTerminalView+SurfaceRuntime+iOS.swift should not register raw surfaces outside the surface owner."
        )
        #expect(
            !findSource.contains("surfaceLifecycleRuntime.setFocus("),
            "GhosttyTerminalView+FindNavigator+iOS.swift should route focus changes through the surface owner."
        )
        #expect(
            !findSource.contains("surface.perform(action:"),
            "GhosttyTerminalView+FindNavigator+iOS.swift should route Ghostty find actions through the surface owner."
        )
        #expect(
            !findSource.contains("guard let surface"),
            "GhosttyTerminalView+FindNavigator+iOS.swift should not unwrap the surface for Ghostty find actions."
        )
        #expect(
            !imeProxySource.contains("surfaceLifecycleRuntime.setFocus("),
            "GhosttyTerminalView+IMEProxy+iOS.swift should route IME focus through the surface owner."
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

    @Test
    func nativeScrollContainerOwnsNotificationTokensOutsideMainActorState() throws {
        let root = try sourceRoot()
        let nativeScrollSource = try source(
            at: root.appendingPathComponent("Waterm/GhosttyTerminal/iOS/Scroll/TerminalNativeScrollContainerView+iOS.swift")
        )

        #expect(
            nativeScrollSource.contains("NotificationObserverTokens"),
            "TerminalNativeScrollContainerView should use the shared observer-token owner for NotificationCenter tokens."
        )
        #expect(
            !nativeScrollSource.contains("scrollbarObserver: NSObjectProtocol"),
            "Scrollbar observer tokens should not be stored as main-actor UI state."
        )
        #expect(
            !nativeScrollSource.contains("cellSizeObserver: NSObjectProtocol"),
            "Cell-size observer tokens should not be stored as main-actor UI state."
        )
        #expect(
            nativeScrollSource.contains("MainActor.assumeIsolated"),
            "Main-queue NotificationCenter callbacks should explicitly hand intent back to the UI actor."
        )
        #expect(
            !nativeScrollSource.contains("handleScrollbarUpdate(notification)"),
            "The non-Sendable Notification payload should be decoded before the main-actor handoff."
        )
    }

    private func source(at url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    private func sourceRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.lastPathComponent != "WatermTests" {
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
