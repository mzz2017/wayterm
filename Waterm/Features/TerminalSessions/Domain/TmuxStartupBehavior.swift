import Foundation

nonisolated enum TmuxStartupBehavior: String, Codable, CaseIterable, Identifiable {
    /// Current behavior: always attach to a Waterm-managed tmux session.
    case watermManaged
    /// Ask user on each new connection.
    case askEveryTime
    /// Start shell without tmux.
    case skipTmux

    var id: String { rawValue }

    static let configCases = allCases

    var displayName: String {
        switch self {
        case .watermManaged:
            return String(localized: "Create Waterm session")
        case .askEveryTime:
            return String(localized: "Ask every time")
        case .skipTmux:
            return String(localized: "Skip tmux")
        }
    }

    var descriptionText: String {
        switch self {
        case .watermManaged:
            return String(localized: "Always create or attach to a Waterm-managed tmux session for this connection.")
        case .askEveryTime:
            return String(localized: "Show a prompt on each new tab or split so you can choose a session.")
        case .skipTmux:
            return String(localized: "Start a normal shell without tmux session persistence.")
        }
    }
}
