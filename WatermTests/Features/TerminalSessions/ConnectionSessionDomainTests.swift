import XCTest
@testable import Waterm

// Test Context:
// These tests protect connection-session domain values and state snapshots. They
// use pure session fixtures and no SSH runtime; update only when session domain
// semantics intentionally change.

final class ConnectionSessionDomainTests: XCTestCase {
    func testConnectionStateFlagsReflectConnectedAndConnectingStates() {
        XCTAssertTrue(ConnectionState.connected.isConnected)
        XCTAssertFalse(ConnectionState.disconnected.isConnected)
        XCTAssertTrue(ConnectionState.connecting.isConnecting)
        XCTAssertTrue(ConnectionState.reconnecting(attempt: 2).isConnecting)
        XCTAssertFalse(ConnectionState.failed("boom").isConnecting)
    }

    func testConnectionSessionDefaultsToRootTabSession() {
        let session = ConnectionSession(serverId: UUID(), title: "Prod")

        XCTAssertTrue(session.isTabRoot)
        XCTAssertEqual(session.activeTransport, .ssh)
        XCTAssertEqual(session.tmuxStatus, .unknown)
    }
}
