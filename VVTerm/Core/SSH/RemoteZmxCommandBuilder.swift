import Foundation

/// Builds the (small) set of shell commands for the zmx multiplexer.
/// zmx contract (v0.6.0): `zmx attach <name>` create-or-attaches a login $SHELL;
/// no config file, no has-session, no windows/splits; `zmx ls --short` lists bare
/// names; `zmx kill <name> --force` removes a session. Detach happens by closing
/// the connection, so no detach command is needed here.
struct RemoteZmxCommandBuilder {
    enum CommandContext {
        case startupExec
        case interactiveShell
    }

    private let zmx = "zmx"

    /// Probe whether zmx is installed. Emits `okMarker` when present.
    func availabilityProbeCommand(okMarker: String) -> String {
        let body = """
        \(RemoteTerminalBootstrap.shellPathExport());
        if command -v zmx >/dev/null 2>&1 && zmx version >/dev/null 2>&1; then
          printf '\(okMarker)';
        else
          printf '__VVTERM_ZMX_NO__';
        fi
        """
        return "sh -c \(RemoteTerminalBootstrap.shellQuoted(body))"
    }

    /// Create-or-attach a zmx session.
    func attachCommand(sessionName: String, context: CommandContext) -> String {
        let quoted = RemoteTerminalBootstrap.shellQuoted(sessionName)
        let body = "\(RemoteTerminalBootstrap.shellPathExport()); exec \(zmx) attach \(quoted)"
        switch context {
        case .startupExec:
            return body
        case .interactiveShell:
            return "sh -lc \(RemoteTerminalBootstrap.shellQuoted(body))"
        }
    }

    func listSessionsCommand() -> String {
        let body = "\(RemoteTerminalBootstrap.shellPathExport()); \(zmx) ls --short 2>/dev/null"
        return "sh -lc \(RemoteTerminalBootstrap.shellQuoted(body))"
    }

    func killSessionCommand(named sessionName: String) -> String {
        let quoted = RemoteTerminalBootstrap.shellQuoted(sessionName)
        let body = "\(RemoteTerminalBootstrap.shellPathExport()); \(zmx) kill \(quoted) --force 2>/dev/null || true"
        return "sh -lc \(RemoteTerminalBootstrap.shellQuoted(body))"
    }

    /// Parse `zmx ls --short` output (one session name per line).
    func parseSessionList(_ output: String) -> [RemoteTmuxSession] {
        output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { RemoteTmuxSession(name: $0, attachedClients: 0, windowCount: 1) }
    }
}
