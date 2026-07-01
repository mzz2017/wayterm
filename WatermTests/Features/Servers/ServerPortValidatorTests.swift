import XCTest
@testable import Waterm

// Test Context:
// These tests protect the Servers feature's SSH port validation before a draft
// Server reaches connection testing or persistence. Update them only if Waterm
// intentionally changes the supported TCP port range or form normalization
// semantics.

final class ServerPortValidatorTests: XCTestCase {
    func testNormalizedPortAcceptsValidPortAndTrimsWhitespace() {
        XCTAssertEqual(ServerPortValidator.normalizedPort(from: " 2222 "), 2222)
    }

    func testNormalizedPortRejectsZeroAndOutOfRangeValues() {
        XCTAssertNil(ServerPortValidator.normalizedPort(from: "0"))
        XCTAssertNil(ServerPortValidator.normalizedPort(from: "65536"))
        XCTAssertNil(ServerPortValidator.normalizedPort(from: "-1"))
    }

    func testNormalizedPortRejectsNonNumericInput() {
        XCTAssertNil(ServerPortValidator.normalizedPort(from: "22/tcp"))
        XCTAssertNil(ServerPortValidator.normalizedPort(from: ""))
    }
}
