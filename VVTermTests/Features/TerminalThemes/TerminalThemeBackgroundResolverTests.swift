import XCTest
@testable import VVTerm

// Test Context:
// These tests protect terminal background color resolution used by iOS and
// macOS terminal chrome. The invariant is that UI surfaces receive a resolved
// color plus a stable cached hex string without force-unwrapping missing theme
// files or missing background entries. The tests create isolated custom theme
// files and use suite-scoped UserDefaults; update them only when terminal theme
// background fallback or cache semantics intentionally change.

final class TerminalThemeBackgroundResolverTests: XCTestCase {
    func testResolvedBackgroundUsesCustomThemeBackgroundHex() throws {
        let themeName = uniqueThemeName()
        try writeCustomTheme(
            named: themeName,
            content: """
            foreground = #FFFFFF
            background = #123abc
            """
        )
        defer { removeCustomTheme(named: themeName) }

        let resolved = TerminalThemeBackgroundResolver.resolve(
            themeName: themeName,
            fallbackHex: "#000000"
        )

        XCTAssertEqual(
            resolved.storageHex,
            "#123ABC",
            "Theme background resolution should normalize the cached hex from the selected theme."
        )
    }

    func testResolvedBackgroundFallsBackWhenThemeIsMissing() {
        let resolved = TerminalThemeBackgroundResolver.resolve(
            themeName: uniqueThemeName(),
            fallbackHex: "#FEFEFE"
        )

        XCTAssertEqual(
            resolved.storageHex,
            "#FEFEFE",
            "Missing themes should use the caller-provided fallback instead of crashing."
        )
    }

    func testResolvedBackgroundFallsBackWhenBackgroundEntryIsMissing() throws {
        let themeName = uniqueThemeName()
        try writeCustomTheme(
            named: themeName,
            content: """
            foreground = #FFFFFF
            cursor-color = #00FF00
            """
        )
        defer { removeCustomTheme(named: themeName) }

        let resolved = TerminalThemeBackgroundResolver.resolve(
            themeName: themeName,
            fallbackHex: "#010203"
        )

        XCTAssertEqual(
            resolved.storageHex,
            "#010203",
            "Themes without a background entry should use fallback color instead of force-unwrapping nil."
        )
    }

    func testInitialBackgroundUsesCachedHexBeforeResolvingThemeFile() throws {
        let suiteName = "TerminalThemeBackgroundResolverTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set("#AABBCC", forKey: TerminalThemeBackgroundResolver.cacheKey)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let resolved = TerminalThemeBackgroundResolver.initialBackground(
            defaults: defaults,
            themeName: uniqueThemeName(),
            fallbackHex: "#000000"
        )

        XCTAssertEqual(
            resolved.storageHex,
            "#AABBCC",
            "Cached terminal background should be used before attempting theme resolution."
        )
    }

    private func uniqueThemeName() -> String {
        "TerminalThemeBackgroundResolverTests-\(UUID().uuidString)"
    }

    private func writeCustomTheme(named themeName: String, content: String) throws {
        let directory = TerminalThemeStoragePaths.customThemesDirectoryURL()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try content.write(
            to: directory.appendingPathComponent(themeName),
            atomically: true,
            encoding: .utf8
        )
    }

    private func removeCustomTheme(named themeName: String) {
        try? FileManager.default.removeItem(
            atPath: TerminalThemeStoragePaths.customThemeFilePath(for: themeName)
        )
    }

}
