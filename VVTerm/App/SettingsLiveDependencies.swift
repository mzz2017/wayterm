import Foundation

extension SettingsViewDependencies {
    @MainActor
    static var live: SettingsViewDependencies {
        SettingsViewDependencies(
            storeManager: .shared,
            serverManager: .shared,
            syncStore: .shared,
            voiceModelDownloads: .shared
        )
    }
}

extension SettingsView {
    @MainActor
    init() {
        self.init(dependencies: .live)
    }
}
