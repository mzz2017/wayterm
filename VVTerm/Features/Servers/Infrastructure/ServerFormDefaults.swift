import Foundation

struct ServerFormDefaults {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func multiplexer() -> TerminalMultiplexer {
        if let raw = defaults.string(forKey: "terminalMultiplexerDefault"),
           let mux = TerminalMultiplexer(rawValue: raw) {
            return mux
        }
        if defaults.object(forKey: "terminalTmuxEnabledDefault") != nil {
            return .fromLegacyTmuxEnabled(defaults.bool(forKey: "terminalTmuxEnabledDefault"))
        }
        return .tmux
    }

    func tmuxStartupBehavior() -> TmuxStartupBehavior {
        guard let rawValue = defaults.string(forKey: "terminalTmuxStartupBehaviorDefault") else {
            return .askEveryTime
        }
        return TmuxStartupBehavior(rawValue: rawValue) ?? .askEveryTime
    }
}
