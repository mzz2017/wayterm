import Foundation

/// Which terminal multiplexer a connection uses for session persistence.
enum TerminalMultiplexer: String, Codable, CaseIterable, Identifiable {
    case none
    case tmux
    case zmx

    var id: String { rawValue }

    var isEnabled: Bool { self != .none }

    var displayName: String {
        switch self {
        case .none: return String(localized: "Off")
        case .tmux: return String(localized: "tmux")
        case .zmx:  return String(localized: "zmx")
        }
    }

    var descriptionText: String {
        switch self {
        case .none: return String(localized: "Start a normal shell without session persistence.")
        case .tmux: return String(localized: "Use tmux to keep sessions alive across disconnects.")
        case .zmx:  return String(localized: "Use zmx (lightweight) to keep sessions alive across disconnects.")
        }
    }

    /// Migration from the old boolean `tmuxEnabledOverride` / `terminalTmuxEnabledDefault`.
    static func fromLegacyTmuxEnabled(_ enabled: Bool) -> TerminalMultiplexer {
        enabled ? .tmux : .none
    }
}
