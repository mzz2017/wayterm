import Foundation

@MainActor
final class UserDefaultsGeneralSettingsPersistence: GeneralSettingsPersisting {
    static let appearanceModeKey = "appearanceMode"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadGeneralSettings() -> GeneralSettingsPreferenceSnapshot {
        GeneralSettingsPreferenceSnapshot(
            appearanceMode: defaults.string(forKey: Self.appearanceModeKey) ?? AppearanceMode.system.rawValue,
            appLanguage: defaults.string(forKey: AppLanguage.storageKey) ?? AppLanguage.system.rawValue,
            isPrivacyModeEnabled: defaults.object(forKey: PrivacyModeSettings.enabledKey) as? Bool ?? false,
            isAnalyticsEnabled: defaults.object(forKey: AnalyticsTracker.enabledKey) as? Bool ?? true
        )
    }

    func setAppearanceMode(_ value: String) {
        defaults.set(value, forKey: Self.appearanceModeKey)
    }

    func setAppLanguage(_ value: String) {
        defaults.set(value, forKey: AppLanguage.storageKey)
    }

    func setPrivacyModeEnabled(_ value: Bool) {
        defaults.set(value, forKey: PrivacyModeSettings.enabledKey)
    }

    func setAnalyticsEnabled(_ value: Bool) {
        defaults.set(value, forKey: AnalyticsTracker.enabledKey)
    }
}
