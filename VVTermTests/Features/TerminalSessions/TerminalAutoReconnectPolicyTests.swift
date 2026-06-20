import Testing
@testable import VVTerm

// Test Context:
// These tests protect terminal auto-reconnect decisions made from SwiftUI
// lifecycle callbacks such as onAppear, scene activation, and connection-state
// changes. Those callbacks can observe stale display snapshots while the
// application-layer runtime registry still owns an opening or streaming SSH
// connection.
//
// The target invariant is that automatic reconnect may only start when the UI
// is active, reconnect is enabled, no reconnect is already in flight, the
// session/pane snapshot is disconnected, and the manager-owned runtime is not
// opening or streaming. Update these tests only if automatic reconnect is
// intentionally redesigned around a different application-layer lifecycle
// source of truth.
//
// Fakes and assumptions: tests exercise a pure policy. They do not construct
// SwiftUI views, touch Keychain, create terminals, or start network runtimes.
struct TerminalAutoReconnectPolicyTests {
    @Test
    func doesNotReconnectDisconnectedSnapshotWhenRuntimeIsLive() {
        #expect(
            !TerminalAutoReconnectPolicy.shouldAttemptReconnect(
                isSceneActive: true,
                autoReconnectEnabled: true,
                reconnectInFlight: false,
                isSuspendingForBackground: false,
                connectionState: .disconnected,
                hasLiveRuntime: true
            ),
            "A stale disconnected snapshot must not start another reconnect while the registry runtime is opening or streaming."
        )
    }

    @Test
    func reconnectsDisconnectedSnapshotWhenRuntimeIsInactive() {
        #expect(
            TerminalAutoReconnectPolicy.shouldAttemptReconnect(
                isSceneActive: true,
                autoReconnectEnabled: true,
                reconnectInFlight: false,
                isSuspendingForBackground: false,
                connectionState: .disconnected,
                hasLiveRuntime: false
            ),
            "A disconnected snapshot with no live runtime should still trigger automatic reconnect."
        )
    }

    @Test
    func doesNotReconnectWhileBackgroundSuspendIsActive() {
        #expect(
            !TerminalAutoReconnectPolicy.shouldAttemptReconnect(
                isSceneActive: true,
                autoReconnectEnabled: true,
                reconnectInFlight: false,
                isSuspendingForBackground: true,
                connectionState: .disconnected,
                hasLiveRuntime: false
            ),
            "Background teardown must not race an automatic reconnect."
        )
    }
}
