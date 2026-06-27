#if os(iOS)
import Testing
import UIKit
@testable import VVTerm

// Test Context:
// Protects iOS hardware-key repeat eligibility used by GhosttyTerminalView.
// These tests should change only if the product intentionally changes which
// physical keys auto-repeat or which modifier shortcuts suppress repeat.
@Suite(.serialized)
struct GhosttyIOSKeyRepeatPolicyTests {
    @Test
    func navigationAndDeleteKeysRepeatWithoutShortcutModifiers() {
        let repeatableKeys: [UIKeyboardHIDUsage] = [
            .keyboardDeleteOrBackspace,
            .keyboardDeleteForward,
            .keyboardUpArrow,
            .keyboardDownArrow,
            .keyboardLeftArrow,
            .keyboardRightArrow,
            .keyboardHome,
            .keyboardEnd,
            .keyboardPageUp,
            .keyboardPageDown,
        ]

        // Given keys that should behave like held terminal navigation/editing keys.
        for keyCode in repeatableKeys {
            // Then the repeat runtime may start its timer for an unmodified key press.
            #expect(
                TerminalHardwareKeyRepeatPolicy.shouldRepeat(keyCode: keyCode, modifiers: []),
                "\(keyCode) should be eligible for hardware key repeat."
            )
        }
    }

    @Test
    func commandControlAndOptionShortcutsDoNotRepeat() {
        let keyCode = UIKeyboardHIDUsage.keyboardUpArrow

        // Given shortcut-style modifier combinations.
        let blockedModifiers: [UIKeyModifierFlags] = [.command, .control, .alternate]

        for modifiers in blockedModifiers {
            // Then the repeat runtime should not turn shortcut chords into repeated terminal input.
            #expect(
                !TerminalHardwareKeyRepeatPolicy.shouldRepeat(keyCode: keyCode, modifiers: modifiers),
                "\(modifiers) should suppress hardware key repeat."
            )
        }
    }

    @Test
    func printableLetterKeysDoNotUseHardwareRepeatRuntime() {
        // Given text-producing keys, which route through normal text input handling.
        let keyCode = UIKeyboardHIDUsage.keyboardA

        // Then the repeat runtime stays out of the way.
        #expect(!TerminalHardwareKeyRepeatPolicy.shouldRepeat(keyCode: keyCode, modifiers: []))
    }
}
#endif
