import Foundation

@MainActor
private let liveGeneralSettingsPreferenceStore = GeneralSettingsPreferenceStore(
    persistence: UserDefaultsGeneralSettingsPersistence(),
    applyLanguageSelection: { AppLanguage.applySelection($0) }
)

extension GeneralSettingsPreferenceStore {
    @MainActor
    static var live: GeneralSettingsPreferenceStore {
        liveGeneralSettingsPreferenceStore
    }
}

extension SettingsViewDependencies {
    @MainActor
    static var live: SettingsViewDependencies {
        SettingsViewDependencies(
            storeManager: .shared,
            serverManager: .shared,
            generalSettings: .live,
            syncStore: .shared,
            voiceSettings: .live,
            voiceModelDownloads: .shared,
            viewTabConfig: .shared,
            keyStore: .shared,
            trustedHostsStore: .shared
        )
    }
}

extension SettingsView {
    @MainActor
    init() {
        self.init(dependencies: .live)
    }
}
