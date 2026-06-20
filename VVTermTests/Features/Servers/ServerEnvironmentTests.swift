import XCTest
@testable import VVTerm

// Test Context:
// These tests protect server environment domain values, labels, and persistence.
// They use pure enum/model fixtures and no synced server records; update only
// when environment semantics intentionally change.

final class ServerEnvironmentTests: XCTestCase {
    func testBuiltInEnvironmentDisplayUsesLocalizedBuiltIns() {
        XCTAssertEqual(ServerEnvironment.production.displayName, String(localized: "Production"))
        XCTAssertEqual(ServerEnvironment.staging.displayShortName, String(localized: "Stag"))
        XCTAssertEqual(ServerEnvironment.development.displayShortName, String(localized: "Dev"))
    }

    func testCustomEnvironmentDisplayUsesRawValues() {
        let environment = ServerEnvironment(name: "QA", shortName: "QA", colorHex: "#123456")

        XCTAssertEqual(environment.displayName, "QA")
        XCTAssertEqual(environment.displayShortName, "QA")
    }
}
