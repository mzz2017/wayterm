import Testing
import Foundation
@testable import VVTerm

// Test Context:
// These tests protect the iOS foreground-resume workflow that decides whether an
// already-open terminal should reconnect after app/background lifecycle changes.
// The invariant is that reconnect decisions must use manager-owned runtime
// liveness, not only the potentially stale ConnectionSession.connectionState
// snapshot carried for UI display.
// Update these tests only if foreground resume intentionally stops reconnecting
// inactive terminal runtimes, not when the runtime source of truth moves.

struct IOSTerminalViewPolicyTests {
    @Test
    func floatingControlsShowOnlyForPhoneTerminalBrowseModeWithoutBlockingOverlays() {
        // Given the iOS terminal is on a phone, the terminal tab is selected,
        // browse mode is active, and no find or voice overlay is occupying the
        // same floating-control space.
        let visibility = IOSTerminalViewPolicy.floatingControlsVisibility(
            isPhone: true,
            selectedViewId: IOSTerminalViewPolicy.terminalViewId,
            isBrowseModeEnabled: true,
            isFindNavigatorVisible: false,
            isVoiceRecording: false,
            isVoiceButtonEnabled: true,
            hasPendingVoiceReturn: true
        )

        // Then all floating terminal controls are available.
        #expect(visibility.shouldShowControls)
        #expect(visibility.shouldShowVoiceButton)
        #expect(visibility.shouldShowReturnButton)
    }

    @Test
    func floatingControlsHideWhenFindNavigatorIsVisible() {
        // Given the find navigator is visible, it owns the terminal overlay
        // space even if browse mode would otherwise show floating controls.
        let visibility = IOSTerminalViewPolicy.floatingControlsVisibility(
            isPhone: true,
            selectedViewId: IOSTerminalViewPolicy.terminalViewId,
            isBrowseModeEnabled: true,
            isFindNavigatorVisible: true,
            isVoiceRecording: false,
            isVoiceButtonEnabled: true,
            hasPendingVoiceReturn: true
        )

        // Then every floating terminal control stays hidden.
        #expect(!visibility.shouldShowControls)
        #expect(!visibility.shouldShowVoiceButton)
        #expect(!visibility.shouldShowReturnButton)
    }

    @Test
    func floatingControlsHideWhenVoiceRecordingIsActive() {
        // Given voice recording is active, the recording UI owns the floating
        // terminal-control space.
        let visibility = IOSTerminalViewPolicy.floatingControlsVisibility(
            isPhone: true,
            selectedViewId: IOSTerminalViewPolicy.terminalViewId,
            isBrowseModeEnabled: true,
            isFindNavigatorVisible: false,
            isVoiceRecording: true,
            isVoiceButtonEnabled: true,
            hasPendingVoiceReturn: true
        )

        // Then every floating terminal control stays hidden.
        #expect(!visibility.shouldShowControls)
        #expect(!visibility.shouldShowVoiceButton)
        #expect(!visibility.shouldShowReturnButton)
    }

    @Test
    func floatingControlsRespectVoiceButtonAndPendingReturnFlags() {
        // Given the base floating controls are visible but optional voice
        // affordances are disabled by their own state.
        let visibility = IOSTerminalViewPolicy.floatingControlsVisibility(
            isPhone: true,
            selectedViewId: IOSTerminalViewPolicy.terminalViewId,
            isBrowseModeEnabled: true,
            isFindNavigatorVisible: false,
            isVoiceRecording: false,
            isVoiceButtonEnabled: false,
            hasPendingVoiceReturn: false
        )

        // Then keyboard controls remain available while voice-specific buttons
        // stay hidden.
        #expect(visibility.shouldShowControls)
        #expect(!visibility.shouldShowVoiceButton)
        #expect(!visibility.shouldShowReturnButton)
    }

    @Test
    func foregroundReconnectsWhenSnapshotLooksConnectedButRuntimeIsInactive() {
        let sessionId = UUID()
        let session = IOSTerminalSessionSnapshot(
            id: sessionId,
            serverId: UUID()
        )

        // Given a terminal tab is selected and auto-reconnect is enabled, but
        // the manager-owned runtime registry says the selected session is not
        // opening or streaming.
        let action = IOSTerminalViewPolicy.foregroundReconnectAction(
            selectedViewId: IOSTerminalViewPolicy.terminalViewId,
            selectedSession: session,
            selectedSessionHasLiveRuntime: false,
            refreshTerminal: false,
            autoReconnectEnabled: true,
            isSuspendingForBackground: false
        )

        // Then a stale connected UI snapshot must not suppress reconnect.
        #expect(
            action?.shouldReconnect == true,
            "Foreground resume should reconnect when the runtime registry is inactive even if the UI snapshot still says connected."
        )
        #expect(
            action?.shouldForceTerminalVisible == true,
            "A reconnecting foreground session should force the terminal visible so the restarted runtime can attach."
        )
    }

    @Test
    func foregroundDoesNotReconnectWhenSnapshotLooksDisconnectedButRuntimeIsLive() {
        let sessionId = UUID()
        let session = IOSTerminalSessionSnapshot(
            id: sessionId,
            serverId: UUID()
        )

        // Given a terminal tab is selected and auto-reconnect is enabled, but
        // the manager-owned runtime registry still has an opening or streaming
        // runtime for the selected session.
        let action = IOSTerminalViewPolicy.foregroundReconnectAction(
            selectedViewId: IOSTerminalViewPolicy.terminalViewId,
            selectedSession: session,
            selectedSessionHasLiveRuntime: true,
            refreshTerminal: false,
            autoReconnectEnabled: true,
            isSuspendingForBackground: false
        )

        // Then a stale disconnected UI snapshot must not force an extra
        // reconnect over the live runtime.
        #expect(
            action?.shouldReconnect == false,
            "Foreground resume should not reconnect when the runtime registry is still live even if the UI snapshot says disconnected."
        )
        #expect(
            action?.shouldForceTerminalVisible == false,
            "A live runtime should not be forced visible as a reconnect side effect."
        )
    }
}
