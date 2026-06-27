import Foundation

@MainActor
final class UserDefaultsSyncSettingsPersistence: SyncSettingsPreferencePersisting {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadSyncEnabled() -> Bool {
        defaults.object(forKey: SyncSettings.enabledKey) as? Bool ?? true
    }

    func setSyncEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: SyncSettings.enabledKey)
    }
}
