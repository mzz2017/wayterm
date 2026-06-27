import Foundation

@MainActor
private let liveGeneralSettingsPreferenceStore = GeneralSettingsPreferenceStore(
    persistence: UserDefaultsGeneralSettingsPersistence(),
    applyLanguageSelection: { AppLanguage.applySelection($0) }
)

@MainActor
private let liveTerminalSettingsPreferenceStore = TerminalSettingsPreferenceStore(
    persistence: UserDefaultsTerminalSettingsPersistence()
)

extension GeneralSettingsPreferenceStore {
    @MainActor
    static var live: GeneralSettingsPreferenceStore {
        liveGeneralSettingsPreferenceStore
    }
}

extension TerminalSettingsPreferenceStore {
    @MainActor
    static var live: TerminalSettingsPreferenceStore {
        liveTerminalSettingsPreferenceStore
    }
}

extension SettingsViewDependencies {
    @MainActor
    static var live: SettingsViewDependencies {
        SettingsViewDependencies(
            storeManager: .shared,
            serverManager: .shared,
            generalSettings: .live,
            terminalSettings: .live,
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
