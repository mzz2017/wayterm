#if os(iOS)
import Testing
import UIKit
@testable import VVTerm

// Test Context:
// Protects hardware-press bookkeeping extracted from GhosttyTerminalView. The
// state owner records whether a physical key press was sent to Ghostty directly
// or through a Swift fallback event, then provides the matching fallback release
// information when UIKit reports key-up. Update these tests only if hardware
// press/release ownership or fallback semantics intentionally change.
@Suite(.serialized)
struct GhosttyIOSHardwarePressStateTests {
    @MainActor
    @Test
    func fallbackPressReturnsFallbackReleaseRecordOnce() {
        let state = TerminalIOSHardwarePressState()
        let keyCode: UInt16 = 82

        // Given a key press that Ghostty handled through the Swift fallback path.
        state.recordFallbackGhosttyPress(
            keyCode: keyCode,
            fallbackKey: .arrowUp,
            modifiers: [.shift]
        )

        // When UIKit reports the key release.
        let release = state.releaseGhosttyPress(keyCode: keyCode, defaultModifiers: [])

        // Then the release carries the fallback key and modifiers exactly once.
        #expect(release?.fallbackKey == .arrowUp)
        #expect(release?.fallbackModifiers == [.shift])
        #expect(state.releaseGhosttyPress(keyCode: keyCode, defaultModifiers: []) == nil)
        #expect(!state.hasGhosttyPresses)
    }

    @MainActor
    @Test
    func directPressClearsStaleFallbackRecordForSameKeyCode() {
        let state = TerminalIOSHardwarePressState()
        let keyCode: UInt16 = 79

        // Given a previous fallback record for the same physical key code.
        state.recordFallbackGhosttyPress(
            keyCode: keyCode,
            fallbackKey: .arrowRight,
            modifiers: [.shift]
        )

        // When the next key press is handled directly by Ghostty's UIKit key path.
        state.recordDirectGhosttyPress(keyCode: keyCode)

        // Then release does not replay stale fallback information.
        let release = state.releaseGhosttyPress(keyCode: keyCode, defaultModifiers: [.alternate])
        #expect(release?.fallbackKey == nil)
        #expect(release?.fallbackModifiers == [.alternate])
        #expect(!state.hasGhosttyPresses)
    }

    @MainActor
    @Test
    func cancelPressDropsTrackedGhosttyPress() {
        let state = TerminalIOSHardwarePressState()
        let keyCode: UInt16 = 81

        // Given a tracked hardware press.
        state.recordDirectGhosttyPress(keyCode: keyCode)
        #expect(state.hasGhosttyPresses)

        // When UIKit cancels the press sequence.
        state.cancelPress(keyCode: keyCode)

        // Then a later key-up is not treated as a Ghostty release.
        #expect(!state.hasGhosttyPresses)
        #expect(state.releaseGhosttyPress(keyCode: keyCode, defaultModifiers: []) == nil)
    }
}
#endif
