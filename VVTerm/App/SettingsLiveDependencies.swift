import Foundation

extension SettingsViewDependencies {
    @MainActor
    static var live: SettingsViewDependencies {
        SettingsViewDependencies(
            storeManager: .shared,
            serverManager: .shared,
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
