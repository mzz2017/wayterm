import Foundation

nonisolated enum TerminalEntityID: Hashable, Sendable {
    case session(UUID)
    case pane(UUID)
}
