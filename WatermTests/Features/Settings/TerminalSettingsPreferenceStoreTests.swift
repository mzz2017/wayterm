import Foundation
import Testing
@testable import Waterm

// Test Context:
// Terminal settings protect the Settings -> Terminal workflow. The invariant is
// that UI edits flow through an application store and persistence adapter, while
// preserving the existing UserDefaults keys consumed by terminal runtime code.
// Update these tests only if those persisted keys or defaults intentionally
// change as part of a terminal settings migration.

@Suite
@MainActor
struct TerminalSettingsPreferenceStoreTests {
    private let defaults: UserDefaults

    init() {
        let suiteName = "TerminalSettingsPreferenceStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test
    func loadsDefaultTerminalSettingsWhenPreferencesAreMissing() {
        // Given a fresh defaults suite with no terminal preferences.
        clearKeys()

        // When the Settings terminal store is created.
        let store = makeStore()

        // Then defaults match the existing terminal settings behavior.
        #expect(store.fontName == TerminalDefaults.defaultFontName)
        #expect(store.fontSize == TerminalDefaults.defaultFontSize)
        #expect(store.themeName == "Aizen Dark")
        #expect(store.themeNameLight == "Aizen Light")
        #expect(store.usePerAppearanceTheme == true)
        #expect(store.appearanceMode == AppearanceMode.system.rawValue)
        #expect(store.terminalNotificationsEnabled == true)
        #expect(store.terminalProgressEnabled == true)
        #expect(store.terminalAccessoryCustomizationEnabled == true)
        #expect(store.terminalKeyboardDismissButtonEnabled == true)
        #expect(store.multiplexerDefaultRaw == TerminalMultiplexer.tmux.rawValue)
        #expect(store.tmuxStartupBehaviorDefaultRaw == TmuxStartupBehavior.askEveryTime.rawValue)
        #expect(store.copyTrimTrailingWhitespace == true)
        #expect(store.copyCollapseBlankLines == false)
        #expect(store.copyStripShellPrompts == false)
        #expect(store.copyFlattenCommands == false)
        #expect(store.copyRemoveBoxDrawing == false)
        #expect(store.copyStripAnsiCodes == true)
        #expect(store.imagePasteBehaviorRaw == ImagePasteBehavior.askOnce.rawValue)
        #expect(store.keepAliveEnabled == true)
        #expect(store.keepAliveInterval == 30)
        #expect(store.autoReconnect == true)
        #expect(store.cursorStyleRaw == TerminalDefaults.defaultCursorStyle.rawValue)
        #expect(store.cursorBlink == TerminalDefaults.defaultCursorBlink)
    }

    @Test
    func writesTerminalSettingsThroughPersistenceAdapter() {
        // Given an application store backed by isolated UserDefaults.
        clearKeys()
        let store = makeStore()

        // When the user changes terminal settings.
        store.fontName = "Menlo"
        store.fontSize = 15
        store.themeName = "Tokyo Night"
        store.themeNameLight = "GitHub Light"
        store.usePerAppearanceTheme = false
        store.appearanceMode = AppearanceMode.dark.rawValue
        store.terminalNotificationsEnabled = false
        store.terminalProgressEnabled = false
        store.terminalAccessoryCustomizationEnabled = false
        store.terminalKeyboardDismissButtonEnabled = false
        store.multiplexerDefaultRaw = TerminalMultiplexer.zmx.rawValue
        store.tmuxStartupBehaviorDefaultRaw = TmuxStartupBehavior.skipTmux.rawValue
        store.copyTrimTrailingWhitespace = false
        store.copyCollapseBlankLines = true
        store.copyStripShellPrompts = true
        store.copyFlattenCommands = true
        store.copyRemoveBoxDrawing = true
        store.copyStripAnsiCodes = false
        store.imagePasteBehaviorRaw = ImagePasteBehavior.automatic.rawValue
        store.keepAliveEnabled = false
        store.keepAliveInterval = 60
        store.autoReconnect = false
        store.cursorStyleRaw = TerminalCursorStyle.underline.rawValue
        store.cursorBlink = false

        // Then the legacy keys used by terminal runtime readers are updated.
        #expect(defaults.string(forKey: TerminalDefaults.fontNameKey) == "Menlo")
        #expect(defaults.double(forKey: TerminalDefaults.fontSizeKey) == 15)
        #expect(defaults.string(forKey: CloudKitSyncConstants.terminalThemeNameKey) == "Tokyo Night")
        #expect(defaults.string(forKey: CloudKitSyncConstants.terminalThemeNameLightKey) == "GitHub Light")
        #expect(defaults.bool(forKey: CloudKitSyncConstants.terminalUsePerAppearanceThemeKey) == false)
        #expect(defaults.string(forKey: UserDefaultsTerminalSettingsPersistence.appearanceModeKey) == AppearanceMode.dark.rawValue)
        #expect(defaults.bool(forKey: UserDefaultsTerminalSettingsPersistence.terminalNotificationsEnabledKey) == false)
        #expect(defaults.bool(forKey: UserDefaultsTerminalSettingsPersistence.terminalProgressEnabledKey) == false)
        #expect(defaults.bool(forKey: UserDefaultsTerminalSettingsPersistence.terminalAccessoryCustomizationEnabledKey) == false)
        #expect(defaults.bool(forKey: UserDefaultsTerminalSettingsPersistence.terminalKeyboardDismissButtonEnabledKey) == false)
        #expect(defaults.string(forKey: UserDefaultsTerminalSettingsPersistence.terminalMultiplexerDefaultKey) == TerminalMultiplexer.zmx.rawValue)
        #expect(defaults.string(forKey: UserDefaultsTerminalSettingsPersistence.terminalTmuxStartupBehaviorDefaultKey) == TmuxStartupBehavior.skipTmux.rawValue)
        #expect(defaults.bool(forKey: UserDefaultsTerminalSettingsPersistence.terminalCopyTrimTrailingWhitespaceKey) == false)
        #expect(defaults.bool(forKey: UserDefaultsTerminalSettingsPersistence.terminalCopyCollapseBlankLinesKey) == true)
        #expect(defaults.bool(forKey: UserDefaultsTerminalSettingsPersistence.terminalCopyStripShellPromptsKey) == true)
        #expect(defaults.bool(forKey: UserDefaultsTerminalSettingsPersistence.terminalCopyFlattenCommandsKey) == true)
        #expect(defaults.bool(forKey: UserDefaultsTerminalSettingsPersistence.terminalCopyRemoveBoxDrawingKey) == true)
        #expect(defaults.bool(forKey: UserDefaultsTerminalSettingsPersistence.terminalCopyStripAnsiCodesKey) == false)
        #expect(defaults.string(forKey: ImagePasteBehavior.userDefaultsKey) == ImagePasteBehavior.automatic.rawValue)
        #expect(defaults.bool(forKey: UserDefaultsTerminalSettingsPersistence.sshKeepAliveEnabledKey) == false)
        #expect(defaults.integer(forKey: UserDefaultsTerminalSettingsPersistence.sshKeepAliveIntervalKey) == 60)
        #expect(defaults.bool(forKey: UserDefaultsTerminalSettingsPersistence.sshAutoReconnectKey) == false)
        #expect(defaults.string(forKey: TerminalDefaults.cursorStyleKey) == TerminalCursorStyle.underline.rawValue)
        #expect(defaults.bool(forKey: TerminalDefaults.cursorBlinkKey) == false)
    }

    @Test
    func clampsFontSizeBeforePersistenceWrites() {
        // Given an application store that can be called outside the Settings slider.
        clearKeys()
        let store = makeStore()

        // When an out-of-range font size is assigned.
        store.fontSize = 100

        // Then the persisted value remains within the terminal-supported range.
        #expect(store.fontSize == TerminalDefaults.maximumFontSize)
        #expect(defaults.double(forKey: TerminalDefaults.fontSizeKey) == TerminalDefaults.maximumFontSize)
    }

    private func makeStore() -> TerminalSettingsPreferenceStore {
        TerminalSettingsPreferenceStore(
            persistence: UserDefaultsTerminalSettingsPersistence(defaults: defaults)
        )
    }

    private func clearKeys() {
        [
            TerminalDefaults.fontNameKey,
            TerminalDefaults.fontSizeKey,
            CloudKitSyncConstants.terminalThemeNameKey,
            CloudKitSyncConstants.terminalThemeNameLightKey,
            CloudKitSyncConstants.terminalUsePerAppearanceThemeKey,
            UserDefaultsTerminalSettingsPersistence.appearanceModeKey,
            UserDefaultsTerminalSettingsPersistence.terminalNotificationsEnabledKey,
            UserDefaultsTerminalSettingsPersistence.terminalProgressEnabledKey,
            UserDefaultsTerminalSettingsPersistence.terminalAccessoryCustomizationEnabledKey,
            UserDefaultsTerminalSettingsPersistence.terminalKeyboardDismissButtonEnabledKey,
            UserDefaultsTerminalSettingsPersistence.terminalMultiplexerDefaultKey,
            UserDefaultsTerminalSettingsPersistence.terminalTmuxStartupBehaviorDefaultKey,
            UserDefaultsTerminalSettingsPersistence.terminalCopyTrimTrailingWhitespaceKey,
            UserDefaultsTerminalSettingsPersistence.terminalCopyCollapseBlankLinesKey,
            UserDefaultsTerminalSettingsPersistence.terminalCopyStripShellPromptsKey,
            UserDefaultsTerminalSettingsPersistence.terminalCopyFlattenCommandsKey,
            UserDefaultsTerminalSettingsPersistence.terminalCopyRemoveBoxDrawingKey,
            UserDefaultsTerminalSettingsPersistence.terminalCopyStripAnsiCodesKey,
            ImagePasteBehavior.userDefaultsKey,
            UserDefaultsTerminalSettingsPersistence.sshKeepAliveEnabledKey,
            UserDefaultsTerminalSettingsPersistence.sshKeepAliveIntervalKey,
            UserDefaultsTerminalSettingsPersistence.sshAutoReconnectKey,
            TerminalDefaults.cursorStyleKey,
            TerminalDefaults.cursorBlinkKey,
        ].forEach(defaults.removeObject(forKey:))
    }
}
