import Foundation

@MainActor
final class UserDefaultsTerminalSettingsPersistence: TerminalSettingsPersisting {
    static let appearanceModeKey = "appearanceMode"
    static let terminalNotificationsEnabledKey = "terminalNotificationsEnabled"
    static let terminalProgressEnabledKey = "terminalProgressEnabled"
    static let terminalAccessoryCustomizationEnabledKey = "terminalAccessoryCustomizationEnabled"
    static let terminalKeyboardDismissButtonEnabledKey = "terminalKeyboardDismissButtonEnabled"
    static let terminalMultiplexerDefaultKey = "terminalMultiplexerDefault"
    static let terminalTmuxStartupBehaviorDefaultKey = "terminalTmuxStartupBehaviorDefault"
    static let terminalCopyTrimTrailingWhitespaceKey = "terminalCopyTrimTrailingWhitespace"
    static let terminalCopyCollapseBlankLinesKey = "terminalCopyCollapseBlankLines"
    static let terminalCopyStripShellPromptsKey = "terminalCopyStripShellPrompts"
    static let terminalCopyFlattenCommandsKey = "terminalCopyFlattenCommands"
    static let terminalCopyRemoveBoxDrawingKey = "terminalCopyRemoveBoxDrawing"
    static let terminalCopyStripAnsiCodesKey = "terminalCopyStripAnsiCodes"
    static let sshKeepAliveEnabledKey = "sshKeepAliveEnabled"
    static let sshKeepAliveIntervalKey = "sshKeepAliveInterval"
    static let sshAutoReconnectKey = "sshAutoReconnect"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadTerminalSettings() -> TerminalSettingsPreferenceSnapshot {
        TerminalDefaults.applyIfNeeded(defaults: defaults)

        return TerminalSettingsPreferenceSnapshot(
            fontName: storedString(forKey: TerminalDefaults.fontNameKey, defaultValue: TerminalDefaults.defaultFontName),
            fontSize: TerminalDefaults.storedFontSize(defaults: defaults),
            themeName: storedString(forKey: CloudKitSyncConstants.terminalThemeNameKey, defaultValue: "Aizen Dark"),
            themeNameLight: storedString(forKey: CloudKitSyncConstants.terminalThemeNameLightKey, defaultValue: "Aizen Light"),
            usePerAppearanceTheme: storedBool(forKey: CloudKitSyncConstants.terminalUsePerAppearanceThemeKey, defaultValue: true),
            appearanceMode: storedString(forKey: Self.appearanceModeKey, defaultValue: AppearanceMode.system.rawValue),
            terminalNotificationsEnabled: storedBool(forKey: Self.terminalNotificationsEnabledKey, defaultValue: true),
            terminalProgressEnabled: storedBool(forKey: Self.terminalProgressEnabledKey, defaultValue: true),
            terminalAccessoryCustomizationEnabled: storedBool(forKey: Self.terminalAccessoryCustomizationEnabledKey, defaultValue: true),
            terminalKeyboardDismissButtonEnabled: storedBool(forKey: Self.terminalKeyboardDismissButtonEnabledKey, defaultValue: true),
            multiplexerDefaultRaw: storedString(forKey: Self.terminalMultiplexerDefaultKey, defaultValue: TerminalMultiplexer.tmux.rawValue),
            tmuxStartupBehaviorDefaultRaw: storedString(forKey: Self.terminalTmuxStartupBehaviorDefaultKey, defaultValue: TmuxStartupBehavior.askEveryTime.rawValue),
            copyTrimTrailingWhitespace: storedBool(forKey: Self.terminalCopyTrimTrailingWhitespaceKey, defaultValue: true),
            copyCollapseBlankLines: storedBool(forKey: Self.terminalCopyCollapseBlankLinesKey, defaultValue: false),
            copyStripShellPrompts: storedBool(forKey: Self.terminalCopyStripShellPromptsKey, defaultValue: false),
            copyFlattenCommands: storedBool(forKey: Self.terminalCopyFlattenCommandsKey, defaultValue: false),
            copyRemoveBoxDrawing: storedBool(forKey: Self.terminalCopyRemoveBoxDrawingKey, defaultValue: false),
            copyStripAnsiCodes: storedBool(forKey: Self.terminalCopyStripAnsiCodesKey, defaultValue: true),
            imagePasteBehaviorRaw: storedString(forKey: ImagePasteBehavior.userDefaultsKey, defaultValue: ImagePasteBehavior.askOnce.rawValue),
            keepAliveEnabled: storedBool(forKey: Self.sshKeepAliveEnabledKey, defaultValue: true),
            keepAliveInterval: storedInt(forKey: Self.sshKeepAliveIntervalKey, defaultValue: 30),
            autoReconnect: storedBool(forKey: Self.sshAutoReconnectKey, defaultValue: true),
            cursorStyleRaw: storedString(forKey: TerminalDefaults.cursorStyleKey, defaultValue: TerminalDefaults.defaultCursorStyle.rawValue),
            cursorBlink: storedBool(forKey: TerminalDefaults.cursorBlinkKey, defaultValue: TerminalDefaults.defaultCursorBlink)
        )
    }

    func setFontName(_ value: String) {
        defaults.set(value, forKey: TerminalDefaults.fontNameKey)
    }

    func setFontSize(_ value: Double) {
        defaults.set(TerminalDefaults.clampedFontSize(value), forKey: TerminalDefaults.fontSizeKey)
    }

    func setThemeName(_ value: String) {
        defaults.set(value, forKey: CloudKitSyncConstants.terminalThemeNameKey)
    }

    func setThemeNameLight(_ value: String) {
        defaults.set(value, forKey: CloudKitSyncConstants.terminalThemeNameLightKey)
    }

    func setUsePerAppearanceTheme(_ value: Bool) {
        defaults.set(value, forKey: CloudKitSyncConstants.terminalUsePerAppearanceThemeKey)
    }

    func setAppearanceMode(_ value: String) {
        defaults.set(value, forKey: Self.appearanceModeKey)
    }

    func setTerminalNotificationsEnabled(_ value: Bool) {
        defaults.set(value, forKey: Self.terminalNotificationsEnabledKey)
    }

    func setTerminalProgressEnabled(_ value: Bool) {
        defaults.set(value, forKey: Self.terminalProgressEnabledKey)
    }

    func setTerminalAccessoryCustomizationEnabled(_ value: Bool) {
        defaults.set(value, forKey: Self.terminalAccessoryCustomizationEnabledKey)
    }

    func setTerminalKeyboardDismissButtonEnabled(_ value: Bool) {
        defaults.set(value, forKey: Self.terminalKeyboardDismissButtonEnabledKey)
    }

    func setMultiplexerDefaultRaw(_ value: String) {
        defaults.set(value, forKey: Self.terminalMultiplexerDefaultKey)
    }

    func setTmuxStartupBehaviorDefaultRaw(_ value: String) {
        defaults.set(value, forKey: Self.terminalTmuxStartupBehaviorDefaultKey)
    }

    func setCopyTrimTrailingWhitespace(_ value: Bool) {
        defaults.set(value, forKey: Self.terminalCopyTrimTrailingWhitespaceKey)
    }

    func setCopyCollapseBlankLines(_ value: Bool) {
        defaults.set(value, forKey: Self.terminalCopyCollapseBlankLinesKey)
    }

    func setCopyStripShellPrompts(_ value: Bool) {
        defaults.set(value, forKey: Self.terminalCopyStripShellPromptsKey)
    }

    func setCopyFlattenCommands(_ value: Bool) {
        defaults.set(value, forKey: Self.terminalCopyFlattenCommandsKey)
    }

    func setCopyRemoveBoxDrawing(_ value: Bool) {
        defaults.set(value, forKey: Self.terminalCopyRemoveBoxDrawingKey)
    }

    func setCopyStripAnsiCodes(_ value: Bool) {
        defaults.set(value, forKey: Self.terminalCopyStripAnsiCodesKey)
    }

    func setImagePasteBehaviorRaw(_ value: String) {
        defaults.set(value, forKey: ImagePasteBehavior.userDefaultsKey)
    }

    func setKeepAliveEnabled(_ value: Bool) {
        defaults.set(value, forKey: Self.sshKeepAliveEnabledKey)
    }

    func setKeepAliveInterval(_ value: Int) {
        defaults.set(value, forKey: Self.sshKeepAliveIntervalKey)
    }

    func setAutoReconnect(_ value: Bool) {
        defaults.set(value, forKey: Self.sshAutoReconnectKey)
    }

    func setCursorStyleRaw(_ value: String) {
        defaults.set(value, forKey: TerminalDefaults.cursorStyleKey)
    }

    func setCursorBlink(_ value: Bool) {
        defaults.set(value, forKey: TerminalDefaults.cursorBlinkKey)
    }

    private func storedString(forKey key: String, defaultValue: String) -> String {
        defaults.string(forKey: key) ?? defaultValue
    }

    private func storedBool(forKey key: String, defaultValue: Bool) -> Bool {
        defaults.object(forKey: key) as? Bool ?? defaultValue
    }

    private func storedInt(forKey key: String, defaultValue: Int) -> Int {
        defaults.object(forKey: key) as? Int ?? defaultValue
    }
}
