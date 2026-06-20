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
    func foregroundReconnectsWhenSnapshotLooksConnectedButRuntimeIsInactive() {
        let sessionId = UUID()
        let session = IOSTerminalSessionSnapshot(
            id: sessionId,
            serverId: UUID(),
            connectionState: .connected
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
}
