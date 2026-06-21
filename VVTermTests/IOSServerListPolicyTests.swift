import XCTest
@testable import VVTerm

// Test Context:
// These tests protect the iOS server list and Active Connections policies.
// The Active Connections invariant is that opening an existing terminal should
// reconnect from manager-owned runtime liveness, not from potentially stale
// ConnectionSession.connectionState snapshots used for display.
// Update these tests only if the iOS home screen intentionally changes how it
// counts active connections or stops reconnecting inactive terminal runtimes.

final class IOSServerListPolicyTests: XCTestCase {
    func testServerListConnectionsForceNewConnectionInstances() {
        XCTAssertTrue(IOSServerListPolicy.shouldForceNewConnectionFromServerList)
    }

    func testActiveConnectionOpenReconnectsWhenRuntimeIsInactive() {
        XCTAssertTrue(
            IOSServerListPolicy.shouldReconnectActiveConnection(sessionHasLiveRuntime: false),
            "Opening an Active Connection should reconnect when the registry says no runtime is live."
        )
    }

    func testActiveConnectionOpenDoesNotReconnectWhenRuntimeIsLive() {
        XCTAssertFalse(
            IOSServerListPolicy.shouldReconnectActiveConnection(sessionHasLiveRuntime: true),
            "Opening an Active Connection should reuse the existing terminal when the registry is opening or streaming."
        )
    }
}
