#if os(iOS)
import Foundation
import UIKit

@MainActor
final class TerminalIOSSurfaceInputRuntime {
    func sendText(_ text: String, surface: Ghostty.Surface?) {
        surface?.sendText(text)
    }

    @discardableResult
    func perform(action: String, surface: Ghostty.Surface?) -> Bool {
        surface?.perform(action: action) ?? false
    }

    func sendKeyPress(
        _ key: Ghostty.Input.Key,
        surface: Ghostty.Surface?,
        using inputRuntime: TerminalIOSInputRuntime
    ) {
        inputRuntime.sendKeyPress(key) { event in
            surface?.sendKeyEvent(event)
        }
    }

    func sendModifiedKey(
        _ key: Ghostty.Input.Key,
        mods: Ghostty.Input.Mods,
        text: String?,
        unshiftedCodepoint: UInt32,
        surface: Ghostty.Surface?,
        using inputRuntime: TerminalIOSInputRuntime
    ) {
        inputRuntime.sendModifiedKey(
            key,
            mods: mods,
            text: text,
            unshiftedCodepoint: unshiftedCodepoint
        ) { event in
            surface?.sendKeyEvent(event)
        }
    }

    func sendKeyEvent(_ event: Ghostty.Input.KeyEvent, surface: Ghostty.Surface?) {
        surface?.sendKeyEvent(event)
    }

    func sendMousePosition(_ position: CGPoint, surface: Ghostty.Surface?) {
        surface?.sendMousePos(.init(x: position.x, y: position.y, mods: []))
    }

    func sendMouseButton(_ event: Ghostty.Input.MouseButtonEvent, surface: Ghostty.Surface?) {
        surface?.sendMouseButton(event)
    }

    func sendMouseScroll(_ event: Ghostty.Input.MouseScrollEvent, surface: Ghostty.Surface?) {
        surface?.sendMouseScroll(event)
    }

    func sendDirectHardwareKeyEvent(
        _ key: UIKey,
        action: ghostty_input_action_e,
        surface: Ghostty.Surface?,
        using inputRuntime: TerminalIOSInputRuntime
    ) -> Bool {
        guard let cSurface = surface?.unsafeCValue else { return false }
        return inputRuntime.sendDirectHardwareKeyEvent(key, action: action, surface: cSurface)
    }

    func syncVisiblePreedit(
        _ text: String?,
        inputModePrimaryLanguage: String?,
        surface: Ghostty.Surface?,
        using inputRuntime: TerminalIOSInputRuntime
    ) -> Bool {
        inputRuntime.syncVisiblePreedit(
            text,
            inputModePrimaryLanguage: inputModePrimaryLanguage,
            surface: surface?.unsafeCValue
        )
    }

    func imePoint(surface: Ghostty.Surface?, using inputRuntime: TerminalIOSInputRuntime) -> CGRect? {
        guard let cSurface = surface?.unsafeCValue else { return nil }
        return inputRuntime.imePoint(surface: cSurface)
    }
}
#endif
