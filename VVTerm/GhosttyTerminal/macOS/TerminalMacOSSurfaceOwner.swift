//
//  TerminalMacOSSurfaceOwner.swift
//  VVTerm
//
//  Stable owner for macOS Ghostty app and surface references.
//

#if os(macOS)
import AppKit
import CoreGraphics
import Foundation

@MainActor
final class TerminalMacOSSurfaceOwner {
    let ghosttyApp: ghostty_app_t
    weak var appWrapper: Ghostty.App?
    var surface: Ghostty.Surface?

    init(ghosttyApp: ghostty_app_t, appWrapper: Ghostty.App?) {
        self.ghosttyApp = ghosttyApp
        self.appWrapper = appWrapper
    }

    func tickDisplayLink(_ displayLinkRuntime: TerminalMacOSDisplayLinkRuntime, isShuttingDown: Bool) {
        displayLinkRuntime.tick(
            isShuttingDown: isShuttingDown,
            surface: surface?.unsafeCValue,
            appTick: { [weak appWrapper] in
                appWrapper?.appTick()
            }
        )
    }

    func hasSelection() -> Bool {
        guard let cSurface = surface?.unsafeCValue else { return false }
        return ghostty_surface_has_selection(cSurface)
    }

    @discardableResult
    func forceRefresh(backingSize: CGSize) -> Bool {
        guard let cSurface = surface?.unsafeCValue else { return false }

        ghostty_surface_set_size(
            cSurface,
            UInt32(backingSize.width),
            UInt32(backingSize.height)
        )

        ghostty_surface_refresh(cSurface)
        ghostty_surface_draw(cSurface)
        appWrapper?.appTick()
        return true
    }

    @discardableResult
    func updateSurfaceConfig(_ presentationOverrides: TerminalPresentationOverrides) -> Bool {
        guard let cSurface = surface?.unsafeCValue else { return false }
        appWrapper?.updateSurfaceConfig(cSurface, presentationOverrides: presentationOverrides)
        return true
    }

    func writeOutput(_ data: Data) {
        guard let cSurface = surface?.unsafeCValue else { return }
        data.withUnsafeBytes { buffer in
            guard let ptr = buffer.baseAddress?.assumingMemoryBound(to: CChar.self) else { return }
            ghostty_surface_write_output(cSurface, ptr, UInt(buffer.count))
        }
    }

    func externalExited(_ exitCode: UInt32) {
        guard let cSurface = surface?.unsafeCValue else { return }
        ghostty_surface_external_exited(cSurface, exitCode)
    }

    func sendText(_ text: String) {
        surface?.sendText(text)
    }

    @discardableResult
    func perform(action: String) -> Bool {
        surface?.perform(action: action) ?? false
    }

    func sendKeyEvent(_ event: Ghostty.Input.KeyEvent) {
        surface?.sendKeyEvent(event)
    }

    func sendRawKeyEvent(_ event: ghostty_input_key_s) {
        guard let cSurface = surface?.unsafeCValue else { return }
        ghostty_surface_key(cSurface, event)
    }

    func sendMouseButton(_ event: Ghostty.Input.MouseButtonEvent) {
        surface?.sendMouseButton(event)
    }

    func sendMousePos(_ event: Ghostty.Input.MousePosEvent) {
        surface?.sendMousePos(event)
    }

    func sendMouseScroll(_ event: Ghostty.Input.MouseScrollEvent) {
        surface?.sendMouseScroll(event)
    }

    func syncPreedit(_ text: String?) {
        guard let cSurface = surface?.unsafeCValue else { return }

        guard let text, !text.isEmpty else {
            ghostty_surface_preedit(cSurface, nil, 0)
            return
        }

        let len = text.utf8CString.count
        guard len > 0 else {
            ghostty_surface_preedit(cSurface, nil, 0)
            return
        }
        text.withCString { ptr in
            ghostty_surface_preedit(cSurface, ptr, UInt(len - 1))
        }
    }

    func imePoint() -> NSRect? {
        guard let cSurface = surface?.unsafeCValue else { return nil }

        var x: Double = 0
        var y: Double = 0
        var width: Double = 0
        var height: Double = 0
        ghostty_surface_ime_point(cSurface, &x, &y, &width, &height)

        return NSRect(x: x, y: y, width: width, height: height)
    }
}
#endif
