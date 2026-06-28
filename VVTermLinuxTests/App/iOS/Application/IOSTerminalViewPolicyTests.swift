import XCTest
@testable import VVTermTerminalSessionsApplicationLogic

// Test Context: protects pure iOS terminal presentation policy owned by
// TerminalSessions/Application. Update these tests when terminal foreground,
// reconnect, or recovered-state semantics change.

final class IOSTerminalViewPolicyTests: XCTestCase {
    func testEffectiveSelectedSessionUsesSelectedSessionWhenItBelongsToCurrentServer() {
        let selected = UUID()
        let fallback = UUID()

        let result = IOSTerminalViewPolicy.effectiveSelectedSessionId(
            selectedSessionId: selected,
            serverSessionIds: [fallback, selected]
        )

        XCTAssertEqual(result, selected)
    }

    func testEffectiveSelectedSessionFallsBackToFirstServerSession() {
        let selectedElsewhere = UUID()
        let fallback = UUID()

        let result = IOSTerminalViewPolicy.effectiveSelectedSessionId(
            selectedSessionId: selectedElsewhere,
            serverSessionIds: [fallback]
        )

        XCTAssertEqual(result, fallback)
    }

    func testPrepareTerminalRefreshesExistingTerminalOnlyForTerminalView() {
        let sessionId = UUID()

        let result = IOSTerminalViewPolicy.terminalPreparation(
            sessionId: sessionId,
            selectedViewId: "terminal",
            terminalAlreadyExists: true,
            isTerminalAlreadyScheduled: false
        )

        XCTAssertEqual(result, .refreshExisting(sessionId))
    }

    func testForegroundReconnectRequestsReconnectForDisconnectedTerminalSession() {
        let sessionId = UUID()

        let result = IOSTerminalViewPolicy.foregroundReconnectAction(
            selectedViewId: "terminal",
            selectedSession: IOSTerminalSessionSnapshot(id: sessionId, serverId: UUID()),
            selectedSessionHasLiveRuntime: false,
            refreshTerminal: true,
            autoReconnectEnabled: true,
            isSuspendingForBackground: false
        )

        XCTAssertEqual(result, IOSTerminalForegroundReconnectAction(
            sessionId: sessionId,
            shouldRefreshTerminal: true,
            shouldReconnect: true,
            shouldForceTerminalVisible: true
        ))
    }

    func testRecoveredStateRequestsDismissalAndDisablesZenWhenNoTerminalContextRemains() {
        let result = IOSTerminalViewPolicy.recoveredTerminalState(
            canUseZenMode: false,
            requestedTerminalDismissal: false
        )

        XCTAssertEqual(result, IOSTerminalRecoveredState(
            shouldShowZenPanel: false,
            isZenModeEnabled: false,
            requestedTerminalDismissal: true,
            shouldCallBack: true
        ))
    }

    func testRecoveredStatePreservesZenVisibilityWhenTerminalContextStillExists() {
        let result = IOSTerminalViewPolicy.recoveredTerminalState(
            canUseZenMode: true,
            requestedTerminalDismissal: true
        )

        XCTAssertEqual(result.shouldShowZenPanel, nil)
        XCTAssertEqual(result.isZenModeEnabled, nil)
        XCTAssertEqual(result.requestedTerminalDismissal, false)
        XCTAssertFalse(result.shouldCallBack)
    }
}
