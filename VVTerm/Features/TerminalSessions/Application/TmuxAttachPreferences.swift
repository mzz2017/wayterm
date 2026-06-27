import Foundation

@MainActor
protocol TmuxAttachPreferenceProviding {
    var tmuxStartupBehaviorDefault: TmuxStartupBehavior { get }
    var multiplexerDefault: TerminalMultiplexer { get }
}

#if DEBUG
struct FixedTmuxAttachPreferences: TmuxAttachPreferenceProviding {
    var tmuxStartupBehaviorDefault: TmuxStartupBehavior
    var multiplexerDefault: TerminalMultiplexer

    init(
        tmuxStartupBehaviorDefault: TmuxStartupBehavior = .askEveryTime,
        multiplexerDefault: TerminalMultiplexer = .tmux
    ) {
        self.tmuxStartupBehaviorDefault = tmuxStartupBehaviorDefault
        self.multiplexerDefault = multiplexerDefault
    }
}
#endif

struct UserDefaultsTmuxAttachPreferences: TmuxAttachPreferenceProviding {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var tmuxStartupBehaviorDefault: TmuxStartupBehavior {
        guard let rawValue = defaults.string(forKey: "terminalTmuxStartupBehaviorDefault") else {
            return .askEveryTime
        }
        return TmuxStartupBehavior(rawValue: rawValue) ?? .askEveryTime
    }

    var multiplexerDefault: TerminalMultiplexer {
        if let raw = defaults.string(forKey: "terminalMultiplexerDefault"),
           let mux = TerminalMultiplexer(rawValue: raw) {
            return mux
        }
        if defaults.object(forKey: "terminalTmuxEnabledDefault") != nil {
            return .fromLegacyTmuxEnabled(defaults.bool(forKey: "terminalTmuxEnabledDefault"))
        }
        return .tmux
    }
}
