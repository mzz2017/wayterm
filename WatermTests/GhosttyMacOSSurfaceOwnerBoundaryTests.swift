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
            at: root.appendingPathComponent("Waterm/GhosttyTerminal/macOS/GhosttyTerminalView+macOS.swift")
        )
        let ownerSource = try source(
            at: root.appendingPathComponent("Waterm/GhosttyTerminal/macOS/TerminalMacOSSurfaceOwner.swift")
        )
        let inputHandlerSource = try source(
            at: root.appendingPathComponent("Waterm/GhosttyTerminal/macOS/GhosttyInputHandler.swift")
        )
        let imeHandlerSource = try source(
            at: root.appendingPathComponent("Waterm/GhosttyTerminal/macOS/GhosttyIMEHandler.swift")
        )
        let scrollViewSource = try source(
            at: root.appendingPathComponent("Waterm/GhosttyTerminal/macOS/TerminalScrollView.swift")
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
        #expect(ownerSource.contains("func cleanup("))
        #expect(ownerSource.contains("func setFocus("))
        #expect(ownerSource.contains("func processExited("))
        #expect(ownerSource.contains("var needsConfirmQuit: Bool"))
        #expect(ownerSource.contains("func terminalSize()"))
        #expect(ownerSource.contains("func setupAppearanceObservation("))
        #expect(ownerSource.contains("func updateBackingProperties("))
        #expect(ownerSource.contains("func updateLayout("))
        #expect(ownerSource.contains("func resizeAndRefresh("))
        #expect(ownerSource.contains("ghostty_surface_set_size("))
        #expect(ownerSource.contains("ghostty_surface_refresh("))
        #expect(ownerSource.contains("ghostty_surface_draw("))
        #expect(ownerSource.contains("ghostty_surface_write_output("))
        #expect(ownerSource.contains("ghostty_surface_external_exited("))
        #expect(ownerSource.contains("ghostty_surface_has_selection("))
        #expect(ownerSource.contains("func sendRawKeyEvent("))
        #expect(ownerSource.contains("func syncPreedit("))
        #expect(ownerSource.contains("func imePoint()"))
        #expect(ownerSource.contains("func sendMouseButton("))
        #expect(ownerSource.contains("func perform(action: String)"))
        #expect(ownerSource.contains("func sendText(_ text: String)"))

        #expect(viewSource.contains("GhosttyIMEHandler(view: self, surfaceOwner: surfaceOwner)"))
        #expect(viewSource.contains("GhosttyInputHandler(view: self, surfaceOwner: surfaceOwner, imeHandler: self.imeHandler)"))
        #expect(viewSource.contains("imeHandler.surfaceDidChange()"))
        #expect(inputHandlerSource.contains("weak var surfaceOwner: TerminalMacOSSurfaceOwner?"))
        #expect(imeHandlerSource.contains("weak var surfaceOwner: TerminalMacOSSurfaceOwner?"))
        #expect(!inputHandlerSource.contains("weak var surface: Ghostty.Surface?"))
        #expect(!imeHandlerSource.contains("weak var surface: Ghostty.Surface?"))
        #expect(!inputHandlerSource.contains("unsafeCValue"))
        #expect(!imeHandlerSource.contains("unsafeCValue"))

        #expect(viewSource.contains("surfaceOwner.cleanup("))
        #expect(viewSource.contains("surfaceOwner.setFocus(true, using: surfaceLifecycleRuntime)"))
        #expect(viewSource.contains("surfaceOwner.updateBackingProperties(for: self, renderingSetup: renderingSetup, window: window)"))
        #expect(viewSource.contains("surfaceOwner.updateLayout("))
        #expect(viewSource.contains("surfaceOwner.processExited(using: surfaceLifecycleRuntime)"))
        #expect(viewSource.contains("surfaceOwner.terminalSize()"))
        #expect(viewSource.contains("surfaceOwner.perform(action: \"reset\")"))
        #expect(viewSource.contains("surfaceOwner.sendText(text)"))
        #expect(scrollViewSource.contains("surfaceView.surfaceOwner.perform(action: \"scroll_to_row:\\(row)\")"))
        #expect(scrollViewSource.contains("surfaceOwner.resizeAndRefresh(backingSize: scaledSize)"))

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
        #expect(
            !viewSource.contains("unsafeCValue"),
            "GhosttyTerminalView+macOS.swift should not access raw Ghostty surface pointers directly."
        )
        #expect(
            !viewSource.contains("surface?.perform"),
            "GhosttyTerminalView+macOS.swift should route surface actions through the surface owner."
        )
        #expect(
            !viewSource.contains("surface?.sendText"),
            "GhosttyTerminalView+macOS.swift should route terminal text writes through the surface owner."
        )
        #expect(
            !scrollViewSource.contains("unsafeCValue"),
            "TerminalScrollView.swift should not access raw Ghostty surface pointers directly."
        )
        #expect(
            !scrollViewSource.contains("surface?.perform"),
            "TerminalScrollView.swift should route surface actions through the surface owner."
        )
        #expect(
            !scrollViewSource.contains("ghostty_surface_set_size("),
            "TerminalScrollView.swift should route resize refresh through the surface owner."
        )
        #expect(
            !scrollViewSource.contains("ghostty_surface_refresh("),
            "TerminalScrollView.swift should route resize refresh through the surface owner."
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
