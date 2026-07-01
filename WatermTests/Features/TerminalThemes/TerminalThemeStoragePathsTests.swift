import XCTest
@testable import Waterm

// Test Context:
// These tests protect terminal theme storage path construction and naming rules.
// They use path fixtures and no user theme mutation; update only when storage
// layout or naming conventions intentionally change.

final class TerminalThemeStoragePathsTests: XCTestCase {
    func testCustomThemeFilePathEndsWithThemeName() {
        let path = TerminalThemeStoragePaths.customThemeFilePath(for: "MyTheme")

        XCTAssertTrue(path.hasSuffix("/CustomThemes/MyTheme") || path.hasSuffix("\\CustomThemes\\MyTheme"))
    }
}
