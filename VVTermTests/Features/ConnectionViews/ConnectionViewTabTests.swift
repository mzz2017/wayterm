import XCTest
@testable import VVTerm

// Test Context:
// These tests protect connection-view tab domain behavior and identity rules.
// They use pure tab values and no SwiftUI rendering; update only when tab model
// semantics intentionally change.

final class ConnectionViewTabTests: XCTestCase {
    func testFromReturnsKnownTab() {
        XCTAssertEqual(ConnectionViewTab.from(id: "stats"), .stats)
        XCTAssertEqual(ConnectionViewTab.from(id: "terminal"), .terminal)
        XCTAssertEqual(ConnectionViewTab.from(id: "files"), .files)
    }

    func testFromReturnsNilForUnknownTab() {
        XCTAssertNil(ConnectionViewTab.from(id: "unknown"))
    }
}
