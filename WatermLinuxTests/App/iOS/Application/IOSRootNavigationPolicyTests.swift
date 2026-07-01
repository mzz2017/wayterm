import XCTest
@testable import WatermIOSApplicationLogic

// Test Context: protects iOS root navigation decisions owned by App/iOS.
// Update these tests when terminal presentation state semantics change, not
// when feature internals move.

final class IOSRootNavigationPolicyTests: XCTestCase {
    func testTerminalNavigationHasContextWhenConnecting() {
        let state = IOSRootNavigationState(
            isConnecting: true,
            connectingServerId: nil,
            sessionServerIds: []
        )

        XCTAssertTrue(IOSRootNavigationPolicy.hasTerminalNavigationContext(state))
    }

    func testTerminalNavigationHasNoContextWhenIdleWithoutSessions() {
        let state = IOSRootNavigationState(
            isConnecting: false,
            connectingServerId: nil,
            sessionServerIds: []
        )

        XCTAssertFalse(IOSRootNavigationPolicy.hasTerminalNavigationContext(state))
    }

    func testShowingTerminalDismissesWhenContextDisappears() {
        let state = IOSRootNavigationState(
            isConnecting: false,
            connectingServerId: nil,
            sessionServerIds: []
        )

        XCTAssertTrue(IOSRootNavigationPolicy.shouldDismissTerminal(isShowingTerminal: true, state: state))
    }

    func testConnectingStateClearsWhenMatchingSessionAppears() {
        let serverId = UUID()
        let state = IOSRootNavigationState(
            isConnecting: true,
            connectingServerId: serverId,
            sessionServerIds: [serverId]
        )

        XCTAssertTrue(IOSRootNavigationPolicy.shouldClearConnectingState(state))
    }
}
