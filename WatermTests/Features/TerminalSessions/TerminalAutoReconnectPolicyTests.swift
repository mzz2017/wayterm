import Testing
@testable import Waterm

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

// Test Context:
// These tests protect user-initiated reconnect decisions made from SwiftUI
// event handlers. The UI snapshot can lag behind the application-owned runtime
// registry after closes, background suspend, or process exit, so the fake
// inputs intentionally combine stale `ConnectionState` values with explicit
// runtime liveness.
//
// The target invariant is that manual retry may start when no retry is already
// in flight and the registry has no opening or streaming runtime. Update these
// tests only if manual retry intentionally stops using registry liveness as its
// source of truth.
//
// Fakes and assumptions: tests exercise a pure policy. They do not construct
// SwiftUI views, touch Keychain, create terminals, or start network runtimes.
struct TerminalManualReconnectPolicyTests {
    @Test
    func retriesStaleConnectingSnapshotWhenRuntimeIsInactive() {
        #expect(
            TerminalManualReconnectPolicy.shouldAttemptReconnect(
                reconnectInFlight: false,
                snapshotState: .connecting,
                hasLiveRuntime: false
            ),
            "A stale connecting snapshot must not block manual retry when the registry has no live runtime."
        )
    }

    @Test
    func doesNotRetryDisconnectedSnapshotWhenRuntimeIsLive() {
        #expect(
            !TerminalManualReconnectPolicy.shouldAttemptReconnect(
                reconnectInFlight: false,
                snapshotState: .disconnected,
                hasLiveRuntime: true
            ),
            "A stale disconnected snapshot must not start another manual retry while the registry runtime is live."
        )
    }

    @Test
    func doesNotRetryWhileRetryIsAlreadyInFlight() {
        #expect(
            !TerminalManualReconnectPolicy.shouldAttemptReconnect(
                reconnectInFlight: true,
                snapshotState: .failed("timeout"),
                hasLiveRuntime: false
            ),
            "UI retry buttons and watchdog callbacks should collapse repeated retry attempts."
        )
    }
}
