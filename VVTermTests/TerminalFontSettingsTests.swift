import Foundation
import Testing
@testable import VVTerm

// Test Context:
// These tests protect terminal font preference defaults, validation, and storage
// behavior. They use isolated settings values and no rendered terminal surface;
// update only when intended font defaults or validation rules change.

struct TerminalFontSettingsTests {

    // MARK: - Fresh default source

    #if os(macOS)
    @Test
    func freshMacOSDefaultsResolveToMenlo() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)

        TerminalDefaults.applyIfNeeded(defaults: defaults)

        let seededName = defaults.string(forKey: TerminalDefaults.fontNameKey)
        #expect(seededName == "Menlo")

        // The Settings @AppStorage initializer uses TerminalDefaults.defaultFontName
        // as its in-memory default, so even before applyIfNeeded runs it would
        // resolve to "Menlo" on macOS.
        #expect(TerminalDefaults.defaultFontName == "Menlo")
    }
    #endif

    #if os(macOS)
    @Test
    func freshMacOSFontSizeIsTwelvePoints() {
        #expect(TerminalDefaults.defaultFontSize == 12.0)
    }
    #endif

    // MARK: - Missing-font injection

    @Test
    func fontListPrependsCurrentFontWhenMissing() {
        let systemFonts = ["Andale Mono", "Courier", "Monaco"]
        let result = TerminalSettingsView.fontListEnsuringCurrentFont(
            systemFonts: systemFonts,
            currentFontName: "Menlo"
        )

        #expect(result.first == "Menlo")
        #expect(result.count == systemFonts.count + 1)
        // Original order preserved after the prepended entry
        #expect(Array(result.dropFirst()) == systemFonts)
    }

    @Test
    func fontListUnchangedWhenCurrentFontAlreadyPresent() {
        let systemFonts = ["Menlo", "Monaco", "Courier"]

        let result = TerminalSettingsView.fontListEnsuringCurrentFont(
            systemFonts: systemFonts,
            currentFontName: "Menlo"
        )

        #expect(result == systemFonts)
    }

    @Test
    func fontListUnchangedForBlankCurrentFont() {
        let systemFonts = ["Menlo", "Monaco"]

        let resultBlank = TerminalSettingsView.fontListEnsuringCurrentFont(
            systemFonts: systemFonts,
            currentFontName: ""
        )
        #expect(resultBlank == systemFonts)

        let resultWhitespace = TerminalSettingsView.fontListEnsuringCurrentFont(
            systemFonts: systemFonts,
            currentFontName: "  \n  "
        )
        #expect(resultWhitespace == systemFonts)
    }

    @Test
    func fontListPrependsCustomFontNotInSystemList() {
        let systemFonts = ["Menlo", "Monaco"]
        let result = TerminalSettingsView.fontListEnsuringCurrentFont(
            systemFonts: systemFonts,
            currentFontName: "MyUninstalledFont"
        )

        #expect(result == ["MyUninstalledFont", "Menlo", "Monaco"])
    }

    @Test
    func fontListDoesNotDuplicateCaseSensitiveMatch() {
        let systemFonts = ["Menlo", "monaco"]
        let result = TerminalSettingsView.fontListEnsuringCurrentFont(
            systemFonts: systemFonts,
            currentFontName: "Menlo"
        )

        // Exact match prevents injection; no duplicate
        #expect(result == systemFonts)
    }

    // MARK: - Fallback families are not forced as primary

    #if os(macOS)
    @Test
    func fallbackFamiliesAreNotDefaultPrimaryFont() {
        let fallbacks = TerminalDefaults.macOSFallbackFontFamilies

        // The default primary font must not be any of the fallback families
        #expect(!fallbacks.contains(TerminalDefaults.defaultFontName))

        // The fallbacks themselves are "Apple SD Gothic Neo" and the legacy default
        #expect(fallbacks.contains("Apple SD Gothic Neo"))
        #expect(fallbacks.contains("JetBrainsMono Nerd Font"))
    }
    #endif

    #if os(macOS)
    @Test
    func settingsDefaultFontIsNotAFallbackFamily() {
        // Verify that the Settings picker default is "Menlo", not a fallback
        #expect(TerminalDefaults.defaultFontName == "Menlo")
        #expect(TerminalDefaults.defaultFontName != "Apple SD Gothic Neo")
        #expect(TerminalDefaults.defaultFontName != "JetBrainsMono Nerd Font")
    }
    #endif
}
