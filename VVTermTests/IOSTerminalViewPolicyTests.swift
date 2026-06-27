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
    func resolvedServerIdPrefersCurrentServerOverDerivedCandidates() {
        let currentServerId = UUID()

        // Given several possible server context sources are available.
        let resolved = IOSTerminalViewPolicy.resolvedServerId(
            currentServerId: currentServerId,
            selectedSessionServerId: UUID(),
            selectedServerId: UUID(),
            connectingServerId: UUID()
        )

        // Then the explicit current server remains the stable context.
        #expect(resolved == currentServerId)
    }

    @Test
    func resolvedServerIdFallsBackThroughSessionSelectedAndConnectingServers() {
        let selectedSessionServerId = UUID()
        let selectedServerId = UUID()
        let connectingServerId = UUID()

        // Given no explicit current server exists, the selected session is the
        // next authoritative runtime context.
        #expect(
            IOSTerminalViewPolicy.resolvedServerId(
                currentServerId: nil,
                selectedSessionServerId: selectedSessionServerId,
                selectedServerId: selectedServerId,
                connectingServerId: connectingServerId
            ) == selectedSessionServerId
        )

        // Given there is no current server or selected session, the selected
        // server drives non-terminal tabs such as Files and Stats.
        #expect(
            IOSTerminalViewPolicy.resolvedServerId(
                currentServerId: nil,
                selectedSessionServerId: nil,
                selectedServerId: selectedServerId,
                connectingServerId: connectingServerId
            ) == selectedServerId
        )

        // Given only a connecting server is available, it still provides enough
        // context for toolbar and disconnect actions while connection opens.
        #expect(
            IOSTerminalViewPolicy.resolvedServerId(
                currentServerId: nil,
                selectedSessionServerId: nil,
                selectedServerId: nil,
                connectingServerId: connectingServerId
            ) == connectingServerId
        )
    }

    @Test
    func resolvedServerIdIsNilWhenNoContextExists() {
        // Given the iOS terminal has no current, selected, or connecting server.
        let resolved = IOSTerminalViewPolicy.resolvedServerId(
            currentServerId: nil,
            selectedSessionServerId: nil,
            selectedServerId: nil,
            connectingServerId: nil
        )

        // Then callers can fall back to defaults or dismiss safely.
        #expect(resolved == nil)
    }

    @Test
    func fileTabServerIdUsesCurrentSelectedThenConnectingServer() {
        let currentServerId = UUID()
        let selectedServerId = UUID()
        let connectingServerId = UUID()

        // Given the Files tab needs a server scope for file-tab routing.
        // Then the explicit current server wins over selected and connecting context.
        #expect(
            IOSTerminalViewPolicy.fileTabServerId(
                currentServerId: currentServerId,
                selectedServerId: selectedServerId,
                connectingServerId: connectingServerId
            ) == currentServerId
        )

        // Given there is no current server yet.
        // Then selected server context is preferred over a connecting fallback.
        #expect(
            IOSTerminalViewPolicy.fileTabServerId(
                currentServerId: nil,
                selectedServerId: selectedServerId,
                connectingServerId: connectingServerId
            ) == selectedServerId
        )

        // Given only a connecting server is available.
        // Then Files can still use that in-progress server context.
        #expect(
            IOSTerminalViewPolicy.fileTabServerId(
                currentServerId: nil,
                selectedServerId: nil,
                connectingServerId: connectingServerId
            ) == connectingServerId
        )
    }

    @Test
    func zenModeAvailabilityRequiresAConnectionContext() {
        // Given the terminal is connecting, selected, or already has sessions.
        // Then zen mode can stay available because there is useful content context.
        #expect(
            IOSTerminalViewPolicy.canUseZenMode(
                isConnecting: true,
                hasSelectedServer: false,
                serverSessionCount: 0
            )
        )
        #expect(
            IOSTerminalViewPolicy.canUseZenMode(
                isConnecting: false,
                hasSelectedServer: true,
                serverSessionCount: 0
            )
        )
        #expect(
            IOSTerminalViewPolicy.canUseZenMode(
                isConnecting: false,
                hasSelectedServer: false,
                serverSessionCount: 1
            )
        )

        // Given there is no connection context.
        // Then zen mode must be disabled by the caller.
        #expect(
            !IOSTerminalViewPolicy.canUseZenMode(
                isConnecting: false,
                hasSelectedServer: false,
                serverSessionCount: 0
            )
        )
    }

    @Test
    func effectiveZenModeRequiresRequestAndAvailableContext() {
        // Given zen mode is requested and usable.
        // Then the effective state is enabled.
        #expect(
            IOSTerminalViewPolicy.effectiveZenModeEnabled(
                isZenModeEnabled: true,
                canUseZenMode: true
            )
        )

        // Given either the request or usable context is missing.
        // Then effective zen mode stays disabled.
        #expect(
            !IOSTerminalViewPolicy.effectiveZenModeEnabled(
                isZenModeEnabled: false,
                canUseZenMode: true
            )
        )
        #expect(
            !IOSTerminalViewPolicy.effectiveZenModeEnabled(
                isZenModeEnabled: true,
                canUseZenMode: false
            )
        )
    }

    @Test
    func viewSwitcherShowsOnlyWhenMultipleTabsAreVisible() {
        // Given one or zero tabs are visible.
        // Then the switcher would be redundant.
        #expect(!IOSTerminalViewPolicy.shouldShowViewSwitcher(visibleTabCount: 0))
        #expect(!IOSTerminalViewPolicy.shouldShowViewSwitcher(visibleTabCount: 1))

        // Given multiple tabs are visible.
        // Then the switcher has meaningful choices.
        #expect(IOSTerminalViewPolicy.shouldShowViewSwitcher(visibleTabCount: 2))
    }

    @Test
    func selectedSessionRecoveryKeepsValidSelection() {
        let currentServerId = UUID()
        let selectedSessionId = UUID()

        // Given the selected session still belongs to the current server.
        let recovery = IOSTerminalViewPolicy.recoveredSelectedSessionId(
            currentServerId: currentServerId,
            selectedSessionId: selectedSessionId,
            serverSessionIds: [selectedSessionId, UUID()]
        )

        // Then no mutation is needed.
        #expect(recovery == nil)
    }

    @Test
    func selectedSessionRecoveryFallsBackWhenSelectionLeavesCurrentServer() {
        let currentServerId = UUID()
        let fallbackSessionId = UUID()

        // Given a stale selected session no longer belongs to the current server.
        let recovery = IOSTerminalViewPolicy.recoveredSelectedSessionId(
            currentServerId: currentServerId,
            selectedSessionId: UUID(),
            serverSessionIds: [fallbackSessionId, UUID()]
        )

        // Then the first current-server session becomes the replacement.
        #expect(recovery == fallbackSessionId)
    }

    @Test
    func selectedSessionRecoveryDoesNotMutateWithoutCurrentServerOrFallback() {
        // Given there is no current server context, selection recovery should
        // wait until the view has enough context to avoid cross-server jumps.
        #expect(
            IOSTerminalViewPolicy.recoveredSelectedSessionId(
                currentServerId: nil,
                selectedSessionId: UUID(),
                serverSessionIds: [UUID()]
            ) == nil
        )

        // Given the current server has no sessions, there is no valid fallback.
        #expect(
            IOSTerminalViewPolicy.recoveredSelectedSessionId(
                currentServerId: UUID(),
                selectedSessionId: UUID(),
                serverSessionIds: []
            ) == nil
        )
    }

    @Test
    func prunedSessionStateKeepsOnlyActiveSessionKeys() {
        let activeSessionId = UUID()
        let removedSessionId = UUID()

        // Given per-session UI state includes entries for current and stale sessions.
        let state = [
            activeSessionId: true,
            removedSessionId: false
        ]

        // When the terminal view reconciles state against the active sessions.
        let pruned = IOSTerminalViewPolicy.prunedSessionState(
            state,
            activeSessionIds: [activeSessionId]
        )

        // Then stale session entries are removed without changing live state.
        #expect(pruned == [activeSessionId: true])
    }

    @Test
    func prunedSessionStateSupportsNonBooleanStateValues() {
        let activeSessionId = UUID()
        let activeToken = UUID()

        // Given reconnect tokens use the same session-scoped pruning rule as
        // terminal visibility and voice state.
        let pruned = IOSTerminalViewPolicy.prunedSessionState(
            [
                activeSessionId: activeToken,
                UUID(): UUID()
            ],
            activeSessionIds: [activeSessionId]
        )

        // Then the shared rule preserves the value type unchanged.
        #expect(pruned == [activeSessionId: activeToken])
    }

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
