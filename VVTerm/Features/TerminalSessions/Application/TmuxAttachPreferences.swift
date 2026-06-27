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
