import Foundation
import Testing
@testable import Waterm

// Test Context:
// These tests protect RemoteFiles macOS inline edit naming policy. The UI may
// ask for a proposed "Untitled Folder" name, but Application policy owns the
// case/diacritic-insensitive collision rule so root browser views do not embed
// naming behavior. Update only if the product intentionally changes how inline
// folder names are proposed.
struct RemoteFileInlineEditPolicyTests {
    @Test
    func uniqueFolderNameUsesBaseNameWhenItDoesNotExist() {
        let proposedName = RemoteFileInlineEditPolicy.uniqueFolderName(
            existingNames: ["Documents", "Downloads"],
            baseName: "Untitled Folder",
            locale: Locale(identifier: "en_US"),
            fallbackSuffix: "fallback"
        )

        #expect(
            proposedName == "Untitled Folder",
            "The first inline folder should use the localized base name."
        )
    }

    @Test
    func uniqueFolderNameSkipsCaseAndDiacriticInsensitiveCollisions() {
        let proposedName = RemoteFileInlineEditPolicy.uniqueFolderName(
            existingNames: ["untitled folder", "Untitled Folder 2", "Untitled Fo\u{0301}lder 3"],
            baseName: "Untitled Folder",
            locale: Locale(identifier: "en_US"),
            fallbackSuffix: "fallback"
        )

        #expect(
            proposedName == "Untitled Folder 4",
            "Inline folder naming should skip existing names after folding case and diacritics."
        )
    }
}
