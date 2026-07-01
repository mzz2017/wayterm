import Combine
import Foundation

struct TerminalSettingsPreferenceSnapshot: Equatable {
    var fontName: String
    var fontSize: Double
    var themeName: String
    var themeNameLight: String
    var usePerAppearanceTheme: Bool
    var appearanceMode: String
    var terminalNotificationsEnabled: Bool
    var terminalProgressEnabled: Bool
    var terminalAccessoryCustomizationEnabled: Bool
    var terminalKeyboardDismissButtonEnabled: Bool
    var multiplexerDefaultRaw: String
    var tmuxStartupBehaviorDefaultRaw: String
    var copyTrimTrailingWhitespace: Bool
    var copyCollapseBlankLines: Bool
    var copyStripShellPrompts: Bool
    var copyFlattenCommands: Bool
    var copyRemoveBoxDrawing: Bool
    var copyStripAnsiCodes: Bool
    var imagePasteBehaviorRaw: String
    var keepAliveEnabled: Bool
    var keepAliveInterval: Int
    var autoReconnect: Bool
    var cursorStyleRaw: String
    var cursorBlink: Bool
}

@MainActor
protocol TerminalSettingsPersisting: AnyObject {
    func loadTerminalSettings() -> TerminalSettingsPreferenceSnapshot
    func setFontName(_ value: String)
    func setFontSize(_ value: Double)
    func setThemeName(_ value: String)
    func setThemeNameLight(_ value: String)
    func setUsePerAppearanceTheme(_ value: Bool)
    func setAppearanceMode(_ value: String)
    func setTerminalNotificationsEnabled(_ value: Bool)
    func setTerminalProgressEnabled(_ value: Bool)
    func setTerminalAccessoryCustomizationEnabled(_ value: Bool)
    func setTerminalKeyboardDismissButtonEnabled(_ value: Bool)
    func setMultiplexerDefaultRaw(_ value: String)
    func setTmuxStartupBehaviorDefaultRaw(_ value: String)
    func setCopyTrimTrailingWhitespace(_ value: Bool)
    func setCopyCollapseBlankLines(_ value: Bool)
    func setCopyStripShellPrompts(_ value: Bool)
    func setCopyFlattenCommands(_ value: Bool)
    func setCopyRemoveBoxDrawing(_ value: Bool)
    func setCopyStripAnsiCodes(_ value: Bool)
    func setImagePasteBehaviorRaw(_ value: String)
    func setKeepAliveEnabled(_ value: Bool)
    func setKeepAliveInterval(_ value: Int)
    func setAutoReconnect(_ value: Bool)
    func setCursorStyleRaw(_ value: String)
    func setCursorBlink(_ value: Bool)
}

@MainActor
final class TerminalSettingsPreferenceStore: ObservableObject {
    @Published var fontName: String {
        didSet { persistence.setFontName(fontName) }
    }

    @Published var fontSize: Double {
        didSet {
            let clamped = TerminalDefaults.clampedFontSize(fontSize)
            if fontSize != clamped {
                fontSize = clamped
            }
            persistence.setFontSize(clamped)
        }
    }

    @Published var themeName: String {
        didSet { persistence.setThemeName(themeName) }
    }

    @Published var themeNameLight: String {
        didSet { persistence.setThemeNameLight(themeNameLight) }
    }

    @Published var usePerAppearanceTheme: Bool {
        didSet { persistence.setUsePerAppearanceTheme(usePerAppearanceTheme) }
    }

    @Published var appearanceMode: String {
        didSet { persistence.setAppearanceMode(appearanceMode) }
    }

    @Published var terminalNotificationsEnabled: Bool {
        didSet { persistence.setTerminalNotificationsEnabled(terminalNotificationsEnabled) }
    }

    @Published var terminalProgressEnabled: Bool {
        didSet { persistence.setTerminalProgressEnabled(terminalProgressEnabled) }
    }

    @Published var terminalAccessoryCustomizationEnabled: Bool {
        didSet { persistence.setTerminalAccessoryCustomizationEnabled(terminalAccessoryCustomizationEnabled) }
    }

    @Published var terminalKeyboardDismissButtonEnabled: Bool {
        didSet { persistence.setTerminalKeyboardDismissButtonEnabled(terminalKeyboardDismissButtonEnabled) }
    }

    @Published var multiplexerDefaultRaw: String {
        didSet { persistence.setMultiplexerDefaultRaw(multiplexerDefaultRaw) }
    }

    @Published var tmuxStartupBehaviorDefaultRaw: String {
        didSet { persistence.setTmuxStartupBehaviorDefaultRaw(tmuxStartupBehaviorDefaultRaw) }
    }

    @Published var copyTrimTrailingWhitespace: Bool {
        didSet { persistence.setCopyTrimTrailingWhitespace(copyTrimTrailingWhitespace) }
    }

    @Published var copyCollapseBlankLines: Bool {
        didSet { persistence.setCopyCollapseBlankLines(copyCollapseBlankLines) }
    }

    @Published var copyStripShellPrompts: Bool {
        didSet { persistence.setCopyStripShellPrompts(copyStripShellPrompts) }
    }

    @Published var copyFlattenCommands: Bool {
        didSet { persistence.setCopyFlattenCommands(copyFlattenCommands) }
    }

    @Published var copyRemoveBoxDrawing: Bool {
        didSet { persistence.setCopyRemoveBoxDrawing(copyRemoveBoxDrawing) }
    }

    @Published var copyStripAnsiCodes: Bool {
        didSet { persistence.setCopyStripAnsiCodes(copyStripAnsiCodes) }
    }

    @Published var imagePasteBehaviorRaw: String {
        didSet { persistence.setImagePasteBehaviorRaw(imagePasteBehaviorRaw) }
    }

    @Published var keepAliveEnabled: Bool {
        didSet { persistence.setKeepAliveEnabled(keepAliveEnabled) }
    }

    @Published var keepAliveInterval: Int {
        didSet { persistence.setKeepAliveInterval(keepAliveInterval) }
    }

    @Published var autoReconnect: Bool {
        didSet { persistence.setAutoReconnect(autoReconnect) }
    }

    @Published var cursorStyleRaw: String {
        didSet { persistence.setCursorStyleRaw(cursorStyleRaw) }
    }

    @Published var cursorBlink: Bool {
        didSet { persistence.setCursorBlink(cursorBlink) }
    }

    private let persistence: any TerminalSettingsPersisting

    init(persistence: any TerminalSettingsPersisting) {
        self.persistence = persistence
        let snapshot = persistence.loadTerminalSettings()
        fontName = snapshot.fontName
        fontSize = snapshot.fontSize
        themeName = snapshot.themeName
        themeNameLight = snapshot.themeNameLight
        usePerAppearanceTheme = snapshot.usePerAppearanceTheme
        appearanceMode = snapshot.appearanceMode
        terminalNotificationsEnabled = snapshot.terminalNotificationsEnabled
        terminalProgressEnabled = snapshot.terminalProgressEnabled
        terminalAccessoryCustomizationEnabled = snapshot.terminalAccessoryCustomizationEnabled
        terminalKeyboardDismissButtonEnabled = snapshot.terminalKeyboardDismissButtonEnabled
        multiplexerDefaultRaw = snapshot.multiplexerDefaultRaw
        tmuxStartupBehaviorDefaultRaw = snapshot.tmuxStartupBehaviorDefaultRaw
        copyTrimTrailingWhitespace = snapshot.copyTrimTrailingWhitespace
        copyCollapseBlankLines = snapshot.copyCollapseBlankLines
        copyStripShellPrompts = snapshot.copyStripShellPrompts
        copyFlattenCommands = snapshot.copyFlattenCommands
        copyRemoveBoxDrawing = snapshot.copyRemoveBoxDrawing
        copyStripAnsiCodes = snapshot.copyStripAnsiCodes
        imagePasteBehaviorRaw = snapshot.imagePasteBehaviorRaw
        keepAliveEnabled = snapshot.keepAliveEnabled
        keepAliveInterval = snapshot.keepAliveInterval
        autoReconnect = snapshot.autoReconnect
        cursorStyleRaw = snapshot.cursorStyleRaw
        cursorBlink = snapshot.cursorBlink
    }
}
