import XCTest
@testable import VVTerm

// Test Context:
// These tests protect terminal accessory validation rules and diagnostics. They
// use pure profile fixtures and no UI presentation; update only when validation
// semantics intentionally change.

final class TerminalAccessoryValidationTests: XCTestCase {
    func testValidationErrorsRemainNonisolatedDomainDiagnostics() throws {
        let validationSource = try String(
            contentsOf: sourceRoot().appendingPathComponent(
                "VVTerm/Features/TerminalAccessories/Domain/TerminalAccessoryValidation.swift"
            ),
            encoding: .utf8
        )
        let profileSource = try String(
            contentsOf: sourceRoot().appendingPathComponent(
                "VVTerm/Features/TerminalAccessories/Domain/TerminalAccessoryProfileModels.swift"
            ),
            encoding: .utf8
        )
        let freeTierSource = try String(
            contentsOf: sourceRoot().appendingPathComponent(
                "VVTerm/Features/Store/Domain/FreeTierLimits.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(
            validationSource.contains("nonisolated var errorDescription"),
            "Terminal accessory validation errors are domain diagnostics and should not inherit MainActor isolation."
        )
        XCTAssertTrue(
            profileSource.contains("nonisolated static let maxCustomActions"),
            "Terminal accessory profile limits are domain constants and should not inherit MainActor isolation."
        )
        XCTAssertTrue(
            freeTierSource.contains("nonisolated static let maxCustomActions"),
            "Free-tier accessory limits are domain constants and should not inherit MainActor isolation."
        )
    }

    func testEmptyTitleErrorMessage() {
        XCTAssertEqual(
            TerminalAccessoryValidationError.emptyTitle.errorDescription,
            "Action title cannot be empty."
        )
    }

    func testCustomActionLimitErrorUsesProfileLimit() {
        XCTAssertEqual(
            TerminalAccessoryValidationError.customActionLimitReached.errorDescription,
            "You can create up to \(TerminalAccessoryProfile.maxCustomActions) custom actions."
        )
    }

    private func sourceRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.lastPathComponent != "VVTermTests" {
            let next = url.deletingLastPathComponent()
            if next.path == url.path {
                throw SourceRootError.notFound
            }
            url = next
        }
        return url.deletingLastPathComponent()
    }

    private enum SourceRootError: Error {
        case notFound
    }
}
