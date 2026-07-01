import Foundation

nonisolated struct RemoteTmuxSession: Hashable {
    let name: String
    let attachedClients: Int
    let windowCount: Int
}

nonisolated enum RemoteTmuxBackend: Hashable, Sendable {
    case unixTmux
    case windowsPsmux(commandName: String, shellFamily: RemoteShellFamily, powerShellExecutable: String?)
    case zmx(commandName: String)

    nonisolated var isWindows: Bool {
        if case .windowsPsmux = self {
            return true
        }
        return false
    }

    nonisolated var isZmx: Bool {
        if case .zmx = self {
            return true
        }
        return false
    }
}

actor RemoteTmuxManager {
    enum CommandContext {
        case startupExec
        case interactiveShell
    }

    static let shared = RemoteTmuxManager()

    let zmxBuilder = RemoteZmxCommandBuilder()
    private let sessionListParser = RemoteTmuxSessionListParser()

    let configDirectory = "~/.waterm"
    let configPath = "~/.waterm/tmux.conf"
    private let availabilityTimeout: Duration = .seconds(8)
    private let listTimeout: Duration = .seconds(12)
    private let configTimeout: Duration = .seconds(20)
    private let killTimeout: Duration = .seconds(10)
    private let cleanupTimeout: Duration = .seconds(20)
    private let pathTimeout: Duration = .seconds(10)

    private init() {}

    func tmuxBackend(
        using client: SSHClient,
        preferred: TerminalMultiplexer = .tmux
    ) async -> RemoteTmuxBackend? {
        try? await availableBackend(using: client, preferred: preferred)
    }

    func availableBackend(
        using executor: any RemoteCommandExecuting,
        preferred: TerminalMultiplexer = .tmux
    ) async throws -> RemoteTmuxBackend? {
        let environment = await executor.remoteEnvironment(forceRefresh: false)
        guard environment.supportsTmuxRuntime else { return nil }

        if environment.platform == .windows {
            // zmx is POSIX-only; Windows always uses psmux.
            return try await windowsPsmuxBackend(for: environment, using: executor)
        }

        if preferred == .zmx {
            let okMarker = "__WATERM_ZMX_OK__"
            let command = zmxBuilder.availabilityProbeCommand(okMarker: okMarker)
            let output = try await availabilityProbeOutput(command, using: executor)
            return output?.contains(okMarker) == true ? .zmx(commandName: "zmx") : nil
        }

        let okMarker = "__WATERM_TMUX_OK__"
        let command = tmuxAvailabilityProbeCommand(okMarker: okMarker)
        let output = try await availabilityProbeOutput(command, using: executor)
        return output?.contains(okMarker) == true ? .unixTmux : nil
    }

    func tmuxInstallBackend(
        using executor: any RemoteCommandExecuting,
        preferred: TerminalMultiplexer = .tmux
    ) async -> RemoteTmuxBackend? {
        let environment = await executor.remoteEnvironment(forceRefresh: false)
        guard environment.supportsTmuxRuntime else { return nil }

        if environment.platform == .windows {
            return .windowsPsmux(
                commandName: "psmux",
                shellFamily: environment.shellProfile.family,
                powerShellExecutable: environment.powerShellExecutable ?? environment.shellProfile.executableName
            )
        }

        // zmx has no remote installer; surface the zmx backend so the caller just attaches.
        if preferred == .zmx {
            return .zmx(commandName: "zmx")
        }

        return .unixTmux
    }

    func isTmuxAvailable(
        using executor: any RemoteCommandExecuting,
        preferred: TerminalMultiplexer = .tmux
    ) async -> Bool {
        (try? await availableBackend(using: executor, preferred: preferred)) != nil
    }

    func listSessions(using executor: any RemoteCommandExecuting) async -> [RemoteTmuxSession] {
        guard let backend = try? await availableBackend(using: executor) else { return [] }
        return await listSessions(using: executor, backend: backend)
    }

    func listSessions(
        using executor: any RemoteCommandExecuting,
        backend: RemoteTmuxBackend
    ) async -> [RemoteTmuxSession] {
        if case .zmx = backend {
            guard let output = try? await executor.execute(zmxBuilder.listSessionsCommand(), timeout: listTimeout) else { return [] }
            return zmxBuilder.parseSessionList(output)
        }

        let candidates = listSessionCommands(backend: backend)

        for (index, command) in candidates.enumerated() {
            guard let output = try? await executor.execute(command, timeout: listTimeout) else { continue }
            let sessions = sessionListParser.parse(output, allowLegacy: index == candidates.count - 1)

            if !sessions.isEmpty {
                return sessions
            }
        }

        return []
    }

    func prepareConfig(
        using executor: any RemoteCommandExecuting,
        terminalType: RemoteTerminalType,
        backend explicitBackend: RemoteTmuxBackend? = nil
    ) async {
        let backend: RemoteTmuxBackend?
        if let explicitBackend {
            backend = explicitBackend
        } else {
            backend = try? await availableBackend(using: executor)
        }
        guard let backend else { return }
        if backend.isZmx { return }   // zmx has no config file
        let command = configWriteExecutionCommand(terminalType: terminalType, backend: backend)
        _ = try? await executor.execute(command, timeout: configTimeout)
    }

    func sendScript(_ script: String, using client: SSHClient, shellId: UUID) async {
        let payload = script.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        guard let data = payload.data(using: .utf8) else { return }
        try? await client.write(data, to: shellId)
    }

    func killSession(
        named sessionName: String,
        using executor: any RemoteCommandExecuting,
        preferred: TerminalMultiplexer = .tmux
    ) async {
        guard let backend = try? await availableBackend(using: executor, preferred: preferred) else { return }
        let command = killSessionCommand(named: sessionName, backend: backend)
        _ = try? await executor.execute(command, timeout: killTimeout)
    }

    func cleanupLegacySessions(using executor: any RemoteCommandExecuting) async {
        guard let backend = try? await availableBackend(using: executor) else { return }
        guard backend == .unixTmux else { return }
        let body = """
        \(RemoteTerminalBootstrap.shellPathExport());
        if command -v tmux >/dev/null 2>&1; then
          tmux list-sessions -F '#{session_name} #{session_attached}' 2>/dev/null | awk '$1 ~ /^waterm_[0-9a-fA-F-]+$/ && $2 == 0 { print $1 }' | while IFS= read -r name; do
            tmux kill-session -t "$name" 2>/dev/null || true;
          done;
        fi
        """
        let command = "sh -lc \(RemoteTerminalBootstrap.shellQuoted(body))"
        _ = try? await executor.execute(command, timeout: cleanupTimeout)
    }

    func cleanupDetachedSessions(
        deviceId: String,
        keeping sessionNames: Set<String>,
        using executor: any RemoteCommandExecuting,
        preferred: TerminalMultiplexer = .tmux
    ) async {
        let prefix = "waterm_\(deviceId)_"
        let keep = sessionNames
        guard let backend = try? await availableBackend(using: executor, preferred: preferred) else { return }
        let sessions = await listSessions(using: executor, backend: backend)

        for session in sessions {
            guard session.name.hasPrefix(prefix) else { continue }
            guard session.attachedClients == 0 else { continue }
            guard !keep.contains(session.name) else { continue }
            await killSession(named: session.name, using: executor, preferred: preferred)
        }
    }

    func currentPath(sessionName: String, using executor: any RemoteCommandExecuting) async -> String? {
        guard let backend = try? await availableBackend(using: executor) else { return nil }
        if backend.isZmx { return nil }   // zmx has no list-panes equivalent
        let command = currentPathCommand(sessionName: sessionName, backend: backend)
        guard let output = try? await executor.execute(command, timeout: pathTimeout) else { return nil }
        let trimmed = output
            .split(separator: "\n", omittingEmptySubsequences: false)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func windowsPsmuxBackend(
        for environment: RemoteEnvironment,
        using executor: any RemoteCommandExecuting
    ) async throws -> RemoteTmuxBackend? {
        let shellFamily = environment.shellProfile.family
        let powerShellExecutable = environment.powerShellExecutable ?? environment.shellProfile.executableName

        for commandName in ["psmux", "pmux"] {
            let backend = RemoteTmuxBackend.windowsPsmux(
                commandName: commandName,
                shellFamily: shellFamily,
                powerShellExecutable: powerShellExecutable
            )
            let output = try await availabilityProbeOutput(
                windowsPsmuxAvailabilityProbeCommand(commandName: commandName, backend: backend, requirePsmuxExtension: false),
                using: executor
            )
            if output?.contains("__WATERM_TMUX_OK__:\(commandName)") == true {
                return backend
            }
        }

        let tmuxBackend = RemoteTmuxBackend.windowsPsmux(
            commandName: "tmux",
            shellFamily: shellFamily,
            powerShellExecutable: powerShellExecutable
        )
        let output = try await availabilityProbeOutput(
            windowsPsmuxAvailabilityProbeCommand(commandName: "tmux", backend: tmuxBackend, requirePsmuxExtension: true),
            using: executor
        )
        if output?.contains("__WATERM_TMUX_OK__:tmux") == true {
            return tmuxBackend
        }

        return nil
    }

    private func availabilityProbeOutput(
        _ command: String,
        using executor: any RemoteCommandExecuting
    ) async throws -> String? {
        do {
            return try await executor.execute(command, timeout: availabilityTimeout)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
    }

}
