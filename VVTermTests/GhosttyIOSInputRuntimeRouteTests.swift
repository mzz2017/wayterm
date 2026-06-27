#if os(iOS)
import Foundation
import Testing
@testable import VVTerm

// Test Context:
// These tests protect iOS IME insert-text routing ownership. GhosttyTerminalView
// may execute UIKit and surface side effects, but pure decisions for committed
// text, toolbar-key equivalents, rich-paste interception, modified Ghostty keys,
// and ANSI fallback bytes should live in TerminalIOSInputRuntime. Update these
// tests only if that policy intentionally moves to another non-UI runtime owner.
@Suite(.serialized)
@MainActor
struct GhosttyIOSInputRuntimeRouteTests {
    @Test
    func imeInsertRouteKeepsPlainTextForLocalIMECommit() {
        let runtime = TerminalIOSInputRuntime()

        // Given plain committed text and no toolbar modifiers.
        let route = runtime.imeInsertRoute(
            for: "a",
            modifiers: .none,
            hasPendingSystemTextInputHardwareKey: false,
            fromIMEComposition: false
        )

        // Then the runtime leaves local IME document mutation to the view.
        guard case .commitTextToIMEProxy("a") = route else {
            Issue.record("Plain text should be routed to the IME proxy document.")
            return
        }
    }

    @Test
    func imeInsertRouteTurnsReturnAndTabIntoGhosttyKeys() {
        let runtime = TerminalIOSInputRuntime()

        // Given newline and tab text from the software keyboard.
        let newlineRoute = runtime.imeInsertRoute(
            for: "\n",
            modifiers: .init(ctrl: true, alt: false, command: false, shift: false),
            hasPendingSystemTextInputHardwareKey: false,
            fromIMEComposition: false
        )
        let tabRoute = runtime.imeInsertRoute(
            for: "\t",
            modifiers: .init(ctrl: false, alt: true, command: false, shift: false),
            hasPendingSystemTextInputHardwareKey: false,
            fromIMEComposition: false
        )

        // Then the runtime preserves modifier policy and asks the view to send Ghostty keys.
        guard case .sendGhosttyKey(.enter, let enterMods, nil, 0, true) = newlineRoute else {
            Issue.record("Return text should route to an Enter Ghostty key.")
            return
        }
        #expect(enterMods.contains(.ctrl))

        guard case .sendGhosttyKey(.tab, let tabMods, nil, 0, true) = tabRoute else {
            Issue.record("Tab text should route to a Tab Ghostty key.")
            return
        }
        #expect(tabMods.contains(.alt))
    }

    @Test
    func imeInsertRouteSeparatesRichPasteAndSystemForwardingIntents() {
        let runtime = TerminalIOSInputRuntime()

        // Given command-like text that should not be written directly.
        let richPasteRoute = runtime.imeInsertRoute(
            for: "v",
            modifiers: .init(ctrl: true, alt: false, command: false, shift: false),
            hasPendingSystemTextInputHardwareKey: false,
            fromIMEComposition: false
        )
        let pendingHardwareRoute = runtime.imeInsertRoute(
            for: "x",
            modifiers: .none,
            hasPendingSystemTextInputHardwareKey: true,
            fromIMEComposition: false
        )

        // Then the runtime exposes explicit intents for the view to execute.
        guard case .interceptRichPaste(let fallbackModifiers) = richPasteRoute else {
            Issue.record("Ctrl+V should ask the app-level rich paste interceptor first.")
            return
        }
        #expect(fallbackModifiers.ctrl)
        guard case .interpretPendingHardwareKey("x") = pendingHardwareRoute else {
            Issue.record("Pending hardware-key text should be interpreted before plain commit.")
            return
        }
    }

    @Test
    func imeInsertRouteOwnsModifiedKeyAndAnsiFallbackPolicy() {
        let runtime = TerminalIOSInputRuntime()

        // Given modified printable input.
        let shiftedBangRoute = runtime.imeInsertRoute(
            for: "!",
            modifiers: .init(ctrl: false, alt: true, command: false, shift: true),
            hasPendingSystemTextInputHardwareKey: false,
            fromIMEComposition: false
        )
        let altUnmappedRoute = runtime.imeInsertRoute(
            for: "é",
            modifiers: .init(ctrl: false, alt: true, command: false, shift: false),
            hasPendingSystemTextInputHardwareKey: false,
            fromIMEComposition: false
        )
        let commandEmojiRoute = runtime.imeInsertRoute(
            for: "😀",
            modifiers: .init(ctrl: false, alt: false, command: true, shift: false),
            hasPendingSystemTextInputHardwareKey: false,
            fromIMEComposition: false
        )

        // Then shortcut-key mappings become Ghostty key events with required shift.
        guard case .sendGhosttyKey(.digit1, let bangMods, nil, 49, false) = shiftedBangRoute else {
            Issue.record("Shifted punctuation should route through Ghostty key mapping.")
            return
        }
        #expect(bangMods.contains(.shift))
        #expect(bangMods.contains(.alt))

        // And non-shortcut modified text uses terminal ANSI fallback bytes.
        guard case .sendAnsiData(let altUnmappedData) = altUnmappedRoute else {
            Issue.record("Alt text without a Ghostty key mapping should route to ANSI fallback data.")
            return
        }
        #expect(altUnmappedData == Data([0x1B, 0xC3, 0xA9]))

        guard case .ignore = commandEmojiRoute else {
            Issue.record("Command-modified unmapped text should be ignored for the system.")
            return
        }
    }
}
#endif
