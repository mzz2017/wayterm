import XCTest
@testable import VVTerm

// Test Context:
// These tests protect terminal preset domain validation and defaults. They use
// pure preset values and no persisted manager; update only when preset schema or
// defaults intentionally change.

final class TerminalPresetTests: XCTestCase {
    func testDefaultTerminalIsBuiltInAndUsesTerminalIcon() {
        XCTAssertTrue(TerminalPreset.defaultTerminal.isBuiltIn)
        XCTAssertEqual(TerminalPreset.defaultTerminal.name, "Terminal")
        XCTAssertEqual(TerminalPreset.defaultTerminal.icon, "terminal")
        XCTAssertEqual(TerminalPreset.defaultTerminal.command, "")
    }
}
