#if os(iOS)
import Foundation
import Testing
@testable import Waterm

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

    @Test
    func imeInsertHandlerDoesNotConsumeModifiersWhenPendingHardwareKeyHandlesText() {
        let runtime = TerminalIOSInputRuntime()
        var modifierConsumptionCount = 0
        var events: [String] = []
        let context = TerminalIOSInputRuntime.IMEInsertExecutionContext(
            consumeModifiers: {
                modifierConsumptionCount += 1
                return .init(ctrl: true, alt: false, command: false, shift: false)
            },
            interpretPendingHardwareKey: { text in
                events.append("pending-\(text)")
                return true
            },
            routeToolbarKey: { key in events.append("toolbar-\(key)") },
            interceptRichPaste: {
                events.append("rich-paste")
                return false
            },
            invalidateLocalTextInputSession: { events.append("invalidate") },
            commitTextToIMEProxy: { text in events.append("commit-\(text)") },
            commitMarkedTextIfNeeded: { events.append("commit-marked") },
            sendGhosttyKey: { key, mods, text, codepoint in
                events.append("ghostty-\(key)-ctrl:\(mods.contains(.ctrl))-\(text ?? "nil")-\(codepoint)")
            },
            sendAnsiData: { data in events.append("ansi-\(Array(data))") },
            sendText: { text in events.append("text-\(text)") }
        )

        // Given text delivered by the system text-input path for a pending hardware key.
        let handled = runtime.handleIMEInsertText(
            "x",
            fromIMEComposition: false,
            hasPendingSystemTextInputHardwareKey: true,
            context: context
        )

        // Then the runtime returns after the pending hardware handler succeeds.
        #expect(handled)
        #expect(modifierConsumptionCount == 0)
        #expect(events == ["pending-x"])
    }

    @Test
    func imeInsertHandlerFallsBackFromRejectedRichPasteWithConsumedModifiers() {
        let runtime = TerminalIOSInputRuntime()
        var modifierConsumptionCount = 0
        var events: [String] = []
        let context = TerminalIOSInputRuntime.IMEInsertExecutionContext(
            consumeModifiers: {
                modifierConsumptionCount += 1
                return .init(ctrl: true, alt: false, command: false, shift: false)
            },
            interpretPendingHardwareKey: { text in
                events.append("pending-\(text)")
                return false
            },
            routeToolbarKey: { key in events.append("toolbar-\(key)") },
            interceptRichPaste: {
                events.append("rich-paste")
                return false
            },
            invalidateLocalTextInputSession: { events.append("invalidate") },
            commitTextToIMEProxy: { text in events.append("commit-\(text)") },
            commitMarkedTextIfNeeded: { events.append("commit-marked") },
            sendGhosttyKey: { key, mods, text, codepoint in
                events.append("ghostty-\(key)-ctrl:\(mods.contains(.ctrl))-\(text ?? "nil")-\(codepoint)")
            },
            sendAnsiData: { data in events.append("ansi-\(Array(data))") },
            sendText: { text in events.append("text-\(text)") }
        )

        // Given Ctrl+V reaches the app rich-paste interceptor but the interceptor declines it.
        let handled = runtime.handleIMEInsertText(
            "v",
            fromIMEComposition: false,
            hasPendingSystemTextInputHardwareKey: false,
            context: context
        )

        // Then fallback uses the already-consumed Ctrl state instead of reading toolbar state again.
        #expect(handled)
        #expect(modifierConsumptionCount == 1)
        #expect(events == ["rich-paste", "ghostty-v-ctrl:true-nil-118"])
    }

    @Test
    func specialKeyRoutingOwnsInvalidationAndEscapeSequencePolicy() {
        let runtime = TerminalIOSInputRuntime()
        var events: [String] = []
        let context = TerminalIOSInputRuntime.TerminalInputExecutionContext(
            invalidateLocalTextInputSession: { events.append("invalidate") },
            sendText: { text in events.append("text-\(text.utf8.map(String.init).joined(separator: ","))") },
            sendGhosttyKey: { key, mods, text, codepoint in
                events.append("ghostty-\(key)-ctrl:\(mods.contains(.ctrl))-\(text ?? "nil")-\(codepoint)")
            }
        )

        // Given cursor movement should preserve the local text input session.
        runtime.handleSpecialKey(.arrowLeft, context: context)

        // And destructive/text-submitting keys should invalidate before sending.
        runtime.handleSpecialKey(.enter, context: context)
        runtime.handleSpecialKey(.delete, context: context)

        #expect(events == [
            "text-27,91,68",
            "invalidate",
            "text-13",
            "invalidate",
            "text-27,91,51,126"
        ])
    }

    @Test
    func controlShortcutAndControlKeyRoutingOwnControlCharacterPolicy() {
        let runtime = TerminalIOSInputRuntime()
        var events: [String] = []
        let context = TerminalIOSInputRuntime.TerminalInputExecutionContext(
            invalidateLocalTextInputSession: { events.append("invalidate") },
            sendText: { text in events.append("text-\(text.utf8.map(String.init).joined(separator: ","))") },
            sendGhosttyKey: { key, mods, text, codepoint in
                events.append("ghostty-\(key)-ctrl:\(mods.contains(.ctrl))-\(text ?? "nil")-\(codepoint)")
            }
        )

        // Given alphabetic shortcuts can be represented as Ghostty key events.
        runtime.handleControlShortcut("C", context: context)

        // And control-key fallback writes the terminal control byte.
        runtime.handleControlKey("d", context: context)

        #expect(events == [
            "ghostty-c-ctrl:true-c-99",
            "text-4"
        ])
    }

    @Test
    func terminalTextRoutingUsesGhosttyKeyMappingWithoutInvalidatingLocalSession() {
        let runtime = TerminalIOSInputRuntime()
        var events: [String] = []
        let context = TerminalIOSInputRuntime.TerminalTextInputExecutionContext(
            sendRawText: { text, invalidateLocalSession in
                events.append("raw-\(text)-invalidate:\(invalidateLocalSession)")
            },
            sendGhosttyKey: { key, mods, text, codepoint, invalidateLocalSession in
                events.append("ghostty-\(key)-shift:\(mods.contains(.shift))-\(text ?? "nil")-\(codepoint)-invalidate:\(invalidateLocalSession)")
            }
        )

        // Given a single printable character with a Ghostty key mapping.
        runtime.handleTerminalInputText("A", context: context)

        // Then it routes as a key event and keeps the local text input session.
        #expect(events == ["ghostty-a-shift:true-A-97-invalidate:false"])
    }

    @Test
    func terminalTextRoutingNormalizesRawTextWithoutInvalidatingLocalSession() {
        let runtime = TerminalIOSInputRuntime()
        var events: [String] = []
        let context = TerminalIOSInputRuntime.TerminalTextInputExecutionContext(
            sendRawText: { text, invalidateLocalSession in
                events.append("raw-\(text.utf8.map(String.init).joined(separator: ","))-invalidate:\(invalidateLocalSession)")
            },
            sendGhosttyKey: { key, mods, text, codepoint, invalidateLocalSession in
                events.append("ghostty-\(key)-shift:\(mods.contains(.shift))-\(text ?? "nil")-\(codepoint)-invalidate:\(invalidateLocalSession)")
            }
        )

        // Given text-model output with line feeds and more than one character.
        runtime.handleTerminalInputText("a\nb", context: context)

        // Then raw terminal text converts LF to CR and does not invalidate the local session.
        #expect(events == ["raw-97,13,98-invalidate:false"])
    }

    @Test
    func terminalTextInputEffectsExecuteInRuntimeOwnedOrder() {
        let runtime = TerminalIOSInputRuntime()
        var events: [String] = []
        let textContext = TerminalIOSInputRuntime.TerminalTextInputExecutionContext(
            sendRawText: { text, invalidateLocalSession in
                events.append("raw-\(text)-invalidate:\(invalidateLocalSession)")
            },
            sendGhosttyKey: { key, mods, text, codepoint, invalidateLocalSession in
                events.append("mapped-\(key)-shift:\(mods.contains(.shift))-\(text ?? "nil")-\(codepoint)-invalidate:\(invalidateLocalSession)")
            }
        )
        let effectContext = TerminalIOSInputRuntime.TerminalTextInputEffectExecutionContext(
            textWillChange: { events.append("will-text") },
            selectionWillChange: { events.append("will-selection") },
            textDidChange: { events.append("did-text") },
            selectionDidChange: { events.append("did-selection") },
            syncPreedit: { text in events.append("preedit-\(text ?? "nil")") },
            terminalTextInput: textContext,
            sendGhosttyKeyPress: { key in events.append("key-\(key)") }
        )

        // Given a mixed set of text-model effects from an IME reconciliation.
        runtime.handleTerminalTextInputEffects(
            [
                .willTextChange,
                .willSelectionChange,
                .syncPreedit("あ"),
                .sendText("A"),
                .sendBackspaces(2),
                .moveCursor(-2),
                .moveCursor(1),
                .sendSpecialKey(.tab),
                .didTextChange,
                .didSelectionChange
            ],
            context: effectContext
        )

        // Then runtime owns the ordering and key expansion while the view only executes callbacks.
        #expect(events == [
            "will-text",
            "will-selection",
            "preedit-あ",
            "mapped-a-shift:true-A-97-invalidate:false",
            "key-backspace",
            "key-backspace",
            "key-arrowLeft",
            "key-arrowLeft",
            "key-arrowRight",
            "key-tab",
            "did-text",
            "did-selection"
        ])
    }

    @Test
    func keyEventSequencingLivesInInputRuntime() {
        let runtime = TerminalIOSInputRuntime()
        var events: [String] = []

        runtime.sendKeyPress(.enter) { event in
            events.append("\(event.key)-\(event.action)-\(event.text ?? "nil")-\(event.unshiftedCodepoint)")
        }

        runtime.sendModifiedKey(
            .a,
            mods: [.ctrl],
            text: nil,
            unshiftedCodepoint: 97
        ) { event in
            events.append("\(event.key)-\(event.action)-ctrl:\(event.mods.contains(.ctrl))-\(event.text ?? "nil")-\(event.unshiftedCodepoint)")
        }

        #expect(events == [
            "enter-press-nil-0",
            "enter-release-nil-0",
            "a-press-ctrl:true-nil-97",
            "a-release-ctrl:true-nil-97"
        ])
    }
}
#endif
