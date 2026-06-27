import Foundation
import Testing
@testable import VVTerm

// Test Context:
// Protects the Settings General preference boundary. GeneralSettingsView should
// bind to this application store while UserDefaults keys and language side
// effects stay behind injected services. Update these tests only when the
// persisted key policy or language-application behavior intentionally changes.
@Suite
@MainActor
struct GeneralSettingsPreferenceStoreTests {
    private let defaults: UserDefaults

    init() {
        let suiteName = "GeneralSettingsPreferenceStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test
    func loadsDefaultGeneralSettingsWhenPreferencesAreMissing() {
        let languageRecorder = LanguageApplicationRecorder()

        // Given empty persisted settings.
        clearKeys()

        // When the application settings store loads the current preferences.
        let store = makeStore(languageRecorder: languageRecorder)

        // Then General UI receives default state without applying language as a side effect.
        #expect(store.appearanceMode == AppearanceMode.system.rawValue)
        #expect(store.appLanguage == AppLanguage.system.rawValue)
        #expect(store.isPrivacyModeEnabled == false)
        #expect(store.isAnalyticsEnabled == true)
        #expect(languageRecorder.appliedLanguages.isEmpty)
    }

    @Test
    func writesGeneralSettingsThroughPersistenceAndAppliesLanguageSelection() {
        let languageRecorder = LanguageApplicationRecorder()

        // Given a General settings store backed by injected persistence.
        clearKeys()
        let store = makeStore(languageRecorder: languageRecorder)

        // When the user changes editable General preferences.
        store.appearanceMode = AppearanceMode.dark.rawValue
        store.appLanguage = AppLanguage.ja.rawValue
        store.isPrivacyModeEnabled = true
        store.isAnalyticsEnabled = false

        // Then preferences are written through the injected persistence service.
        #expect(defaults.string(forKey: UserDefaultsGeneralSettingsPersistence.appearanceModeKey) == AppearanceMode.dark.rawValue)
        #expect(defaults.string(forKey: AppLanguage.storageKey) == AppLanguage.ja.rawValue)
        #expect(defaults.bool(forKey: PrivacyModeSettings.enabledKey) == true)
        #expect(defaults.bool(forKey: AnalyticsTracker.enabledKey) == false)
        #expect(
            languageRecorder.appliedLanguages == [AppLanguage.ja.rawValue],
            "Language selection should be applied exactly when the user changes the stored language."
        )
    }

    private func makeStore(languageRecorder: LanguageApplicationRecorder) -> GeneralSettingsPreferenceStore {
        GeneralSettingsPreferenceStore(
            persistence: UserDefaultsGeneralSettingsPersistence(defaults: defaults),
            applyLanguageSelection: languageRecorder.apply
        )
    }

    private func clearKeys() {
        [
            UserDefaultsGeneralSettingsPersistence.appearanceModeKey,
            AppLanguage.storageKey,
            PrivacyModeSettings.enabledKey,
            AnalyticsTracker.enabledKey,
        ].forEach(defaults.removeObject(forKey:))
    }
}

@MainActor
private final class LanguageApplicationRecorder {
    private(set) var appliedLanguages: [String] = []

    func apply(_ language: String) {
        appliedLanguages.append(language)
    }
}
