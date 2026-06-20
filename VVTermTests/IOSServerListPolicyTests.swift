import XCTest
@testable import VVTerm

final class IOSServerListPolicyTests: XCTestCase {
    func testServerListConnectionsForceNewConnectionInstances() {
        XCTAssertTrue(IOSServerListPolicy.shouldForceNewConnectionFromServerList)
    }
}
