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

    func testListRefreshIdentityIncludesSelectionAndVisibleRowsInStableOrder() {
        let workspaceId = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let environmentId = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let firstServerId = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        let secondServerId = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
        let activeConnectionId = UUID(uuidString: "00000000-0000-0000-0000-000000000005")!

        let identity = IOSServerListPolicy.listRefreshIdentity(
            selectedWorkspaceId: workspaceId,
            selectedEnvironmentId: environmentId,
            filteredServerIds: [firstServerId, secondServerId],
            activeConnectionIds: [activeConnectionId]
        )

        XCTAssertEqual(
            identity,
            [
                workspaceId.uuidString,
                environmentId.uuidString,
                [firstServerId.uuidString, secondServerId.uuidString].joined(separator: ","),
                activeConnectionId.uuidString
            ].joined(separator: "|"),
            "The iOS list refresh identity should change when workspace, environment, visible servers, or Active Connections change."
        )
    }

    func testListRefreshIdentityUsesAllSentinelsWhenNoSelectionOrRowsExist() {
        let identity = IOSServerListPolicy.listRefreshIdentity(
            selectedWorkspaceId: nil,
            selectedEnvironmentId: nil,
            filteredServerIds: [],
            activeConnectionIds: []
        )

        XCTAssertEqual(
            identity,
            "all-workspaces|all-environments||",
            "The iOS list refresh identity should remain deterministic for the all-workspaces/all-environments empty-list state."
        )
    }
}
