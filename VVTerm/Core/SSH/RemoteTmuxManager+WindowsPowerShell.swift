import Foundation

extension RemoteTmuxManager {
    nonisolated func windowsShellCommand(
        powerShellScript: String,
        backend: RemoteTmuxBackend
    ) -> String {
        guard case .windowsPsmux(_, let shellFamily, let powerShellExecutable) = backend else {
            return powerShellScript
        }

        switch shellFamily {
        case .powershell:
            return powerShellScript
        case .cmd, .unknown, .posix:
            let executable = powerShellExecutable ?? "powershell"
            return RemoteTerminalBootstrap.wrapPowerShellCommand(
                powerShellScript,
                executableName: executable
            )
        }
    }

    nonisolated func windowsConfigPathPowerShellExpression() -> String {
        "$HOME + \(powerShellQuoted("\\.vvterm\\psmux.conf"))"
    }

    nonisolated func windowsConfigDirectoryPowerShellExpression() -> String {
        "$HOME + \(powerShellQuoted("\\.vvterm"))"
    }

    nonisolated func windowsWorkingDirectoryExpression(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "$HOME" }
        if trimmed == "~" || trimmed == "$HOME" || trimmed == "%USERPROFILE%" {
            return "$HOME"
        }
        return powerShellQuoted(normalizedWindowsPath(trimmed))
    }

    nonisolated func normalizedWindowsPath(_ value: String) -> String {
        let normalizedSlashes = value.replacingOccurrences(of: "/", with: "\\")
        if value.count >= 2 {
            let prefix = value.prefix(2)
            let drive = prefix.prefix(1)
            if drive.range(of: #"^[A-Za-z]$"#, options: .regularExpression) != nil,
               prefix.dropFirst() == ":" {
                return normalizedSlashes
            }
        }

        if value.count >= 3,
           value.first == "/",
           let drive = value.dropFirst().first,
           drive.isLetter {
            let remainder = value.dropFirst(2)
            let normalizedRemainder = remainder.replacingOccurrences(of: "/", with: "\\")
            return "\(drive.uppercased()):\(normalizedRemainder)"
        }

        return value
    }

    nonisolated func powerShellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "''"))'"
    }

    nonisolated func indentPowerShell(_ value: String, spaces: Int) -> String {
        let prefix = String(repeating: " ", count: spaces)
        return value
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                line.isEmpty ? "" : prefix + line
            }
            .joined(separator: "\n")
    }

    nonisolated func escapeForDoubleQuotes(_ value: String) -> String {
        var escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
        escaped = escaped.replacingOccurrences(of: "\"", with: "\\\"")
        escaped = escaped.replacingOccurrences(of: "$", with: "\\$")
        escaped = escaped.replacingOccurrences(of: "`", with: "\\`")
        return escaped
    }
}
