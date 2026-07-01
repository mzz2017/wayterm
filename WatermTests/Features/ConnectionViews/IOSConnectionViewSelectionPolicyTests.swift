import Testing
@testable import Waterm

// Test Context:
// These tests protect iOS connection-view selection rules after the policy moved
// into ConnectionViews. The policy keeps root and terminal UI code from owning
// fallback rules for hidden tabs. Update these tests only when iOS intentionally
// changes how it chooses the initial or persisted connection view.
struct IOSConnectionViewSelectionPolicyTests {
    @Test
    func preferredConnectViewUsesTerminalWhenTerminalTabIsVisible() {
        // Given Terminal is visible and Files is the configured default.
        let selected = IOSConnectionViewSelectionPolicy.preferredConnectViewId(
            isTerminalVisible: true,
            effectiveDefaultViewId: "files"
        )

        // Then a new server connection opens into Terminal.
        #expect(selected == IOSConnectionViewSelectionPolicy.terminalViewId)
    }

    @Test
    func preferredConnectViewFallsBackToDefaultWhenTerminalTabIsHidden() {
        // Given Terminal is hidden and Files is the configured default.
        let selected = IOSConnectionViewSelectionPolicy.preferredConnectViewId(
            isTerminalVisible: false,
            effectiveDefaultViewId: "files"
        )

        // Then the visible default tab owns the initial view.
        #expect(selected == "files")
    }

    @Test
    func storedViewFallsBackToDefaultWhenRequestedViewIsHidden() {
        // Given a persisted selected view that is no longer visible.
        let selected = IOSConnectionViewSelectionPolicy.storedViewId(
            requestedViewId: "stats",
            isRequestedViewVisible: false,
            effectiveDefaultViewId: "terminal"
        )

        // Then the policy resolves to the current visible default.
        #expect(selected == "terminal")
    }
}
