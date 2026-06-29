import Foundation
import Testing
@testable import VVTerm

// Test Context:
// These tests protect rich clipboard preference persistence and defaults used by
// terminal paste workflows. They use isolated in-memory settings assumptions;
// update only when the intended rich clipboard defaults or keys change.

@MainActor
struct RichClipboardSettingsTests {
    @Test
    func settingsFallbackToAskOnceWhenUnsetOrInvalid() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        defaults.set("bogus", forKey: ImagePasteBehavior.userDefaultsKey)

        let settings = RichClipboardSettings(defaults: defaults)

        #expect(settings.imagePasteBehavior == .askOnce)
        #expect(settings.isImagePasteEnabled)
    }

    @Test
    func settingsReadPersistedAutomaticBehavior() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        defaults.set(ImagePasteBehavior.automatic.rawValue, forKey: ImagePasteBehavior.userDefaultsKey)

        let settings = RichClipboardSettings(defaults: defaults)

        #expect(settings.imagePasteBehavior == .automatic)
        #expect(settings.isImagePasteEnabled)
    }

    @Test
    func settingsReadPersistedDisabledBehavior() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        defaults.set(ImagePasteBehavior.disabled.rawValue, forKey: ImagePasteBehavior.userDefaultsKey)

        let settings = RichClipboardSettings(defaults: defaults)

        #expect(settings.imagePasteBehavior == .disabled)
        #expect(!settings.isImagePasteEnabled)
    }
}
