/// A persisted binding between a pane/session (entity UUID) and the multiplexer
/// session it attached to, so reconnecting after an app restart auto-reattaches
/// instead of re-prompting.
struct TmuxSessionBinding: Codable, Equatable {
    var sessionName: String
    var ownership: String    // "managed" | "external"
    var multiplexer: String  // TerminalMultiplexer.rawValue
}
