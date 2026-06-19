import XCTest
@testable import VVTermIOSApplicationLogic

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
