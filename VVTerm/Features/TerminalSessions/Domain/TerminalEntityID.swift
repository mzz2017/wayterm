import Foundation

enum TerminalEntityID: Hashable, Sendable {
    case session(UUID)
    case pane(UUID)
}
