import XCTest
@testable import Waterm

// Test Context:
// These tests protect the explicit terminal entity lifecycle model introduced
// before moving SSH ownership into runtime objects. The new state enum is a
// domain bridge over the existing ConnectionState and must not change current UI
// behavior by itself.
//
// A failure usually means the lifecycle contract changed: whether a terminal can
// be reused, whether it is considered connected, or how existing ConnectionState
// values map into the new entity state. Update these tests only with an explicit
// lifecycle model change.
final class TerminalEntityStateTests: XCTestCase {
    func testClosingIsNotReusableOrConnected() {
        let state = TerminalEntityConnectionState.closing

        XCTAssertFalse(state.isConnected)
        XCTAssertTrue(state.isClosing)
        XCTAssertFalse(state.isTerminalReusable)
    }

    func testStreamingIsConnectedAndReusable() {
        let state = TerminalEntityConnectionState.streaming

        XCTAssertTrue(state.isConnected)
        XCTAssertFalse(state.isClosing)
        XCTAssertTrue(state.isTerminalReusable)
    }

    func testConnectionStateBridgeMapsConnectedToStreaming() {
        let state = TerminalEntityConnectionState(connectionState: .connected)

        XCTAssertEqual(state, .streaming)
        XCTAssertTrue(state.isConnected)
    }

    func testConnectionStateBridgePreservesReconnectingAsOpening() {
        let state = TerminalEntityConnectionState(connectionState: .reconnecting(attempt: 2))

        XCTAssertEqual(state, .reconnecting)
        XCTAssertTrue(state.isOpening)
        XCTAssertFalse(state.isConnected)
    }

    func testConnectionStateBridgePreservesFailureMessage() {
        let state = TerminalEntityConnectionState(connectionState: .failed("Authentication failed"))

        XCTAssertEqual(state, .failed("Authentication failed"))
        XCTAssertFalse(state.isTerminalReusable)
    }
}
