import Foundation

@MainActor
final class UserDefaultsTerminalRuntimePreferencesPersistence: TerminalRuntimePreferencesPersisting {
    static let terminalThemeNameDefault = "Aizen Dark"
    static let terminalThemeNameLightDefault = "Aizen Light"
    static let sshAutoReconnectKey = "sshAutoReconnect"
    static let terminalVoiceButtonEnabledKey = "terminalVoiceButtonEnabled"

    private let defaults: UserDefaults

    var changeNotificationObject: Any? {
        defaults
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadTerminalRuntimePreferences() -> TerminalRuntimePreferenceSnapshot {
        TerminalRuntimePreferenceSnapshot(
            terminalThemeName: defaults.string(forKey: CloudKitSyncConstants.terminalThemeNameKey) ?? Self.terminalThemeNameDefault,
            terminalThemeNameLight: defaults.string(forKey: CloudKitSyncConstants.terminalThemeNameLightKey) ?? Self.terminalThemeNameLightDefault,
            usePerAppearanceTheme: storedBool(forKey: CloudKitSyncConstants.terminalUsePerAppearanceThemeKey, defaultValue: true),
            autoReconnectEnabled: storedBool(forKey: Self.sshAutoReconnectKey, defaultValue: true),
            terminalVoiceButtonEnabled: storedBool(forKey: Self.terminalVoiceButtonEnabledKey, defaultValue: true)
        )
    }

    private func storedBool(forKey key: String, defaultValue: Bool) -> Bool {
        defaults.object(forKey: key) as? Bool ?? defaultValue
    }
}
