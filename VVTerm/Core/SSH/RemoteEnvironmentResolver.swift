import Foundation

enum RemoteEnvironmentResolver {
    private static let probeTimeout: Duration = .seconds(2)

    static func resolve(using client: SSHClient) async -> RemoteEnvironment {
        let platform = await detectPlatform(using: client)

        switch platform {
        case .windows:
            let activeShell = await detectWindowsShell(using: client)
            let powerShellExecutable = await detectPowerShellExecutable(
                using: client,
                preferredExecutableName: activeShell.powerShellExecutableName
            )
            let profile: RemoteShellProfile
            switch activeShell {
            case .powershell(_):
                profile = .powershell(executableName: activeShell.powerShellExecutableName ?? powerShellExecutable)
            case .cmd:
                profile = .cmd
            case .unknown:
                profile = .unknown(shellName: nil)
            case .posix:
                profile = .posix(shellName: nil)
            }
            return RemoteEnvironment(
                platform: .windows,
                shellProfile: profile,
                activeShellName: profile.shellName,
                powerShellExecutable: powerShellExecutable
            )

        case .linux, .darwin, .freebsd, .openbsd, .netbsd, .unknown:
            let shellName = await detectUnixShellName(using: client)
            let profile = resolveUnixProfile(shellName: shellName)
            return RemoteEnvironment(
                platform: platform,
                shellProfile: profile,
                activeShellName: shellName,
                powerShellExecutable: nil
            )
        }
    }

    private static func detectPlatform(using client: SSHClient) async -> RemotePlatform {
        if let output = await probe("cmd.exe /d /c ver", using: client) {
            let platform = RemotePlatform.detect(from: output)
            if platform == .windows {
                return .windows
            }
        }

        if let output = await probe("uname -s", using: client) {
            return RemotePlatform.detect(from: output)
        }

        if let output = await probe(
            RemoteTerminalBootstrap.wrapPOSIXShellCommand("/usr/bin/uname -s 2>/dev/null || /bin/uname -s 2>/dev/null || uname -s"),
            using: client
        ) {
            return RemotePlatform.detect(from: output)
        }

        return .unknown
    }

    private static func detectUnixShellName(using client: SSHClient) async -> String? {
        let probes = [
            #"printf '%s' "$SHELL" 2>/dev/null"#,
            #"ps -p $$ -o comm= 2>/dev/null"#,
        ]

        for command in probes {
            guard let output = await probe(command, using: client) else { continue }
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let normalized = (trimmed as NSString).lastPathComponent.lowercased()
            return normalized.isEmpty ? nil : normalized
        }

        return nil
    }

    private static func resolveUnixProfile(shellName: String?) -> RemoteShellProfile {
        guard let shellName else {
            return .posix(shellName: "sh")
        }

        switch shellName {
        case "bash", "zsh", "sh", "dash", "ksh", "ash", "fish", "elvish":
            return .posix(shellName: shellName)
        case "nu", "nushell":
            return .posix(shellName: shellName)
        default:
            return .posix(shellName: shellName)
        }
    }

    nonisolated static func powerShellExecutableCandidates(preferredExecutableName: String?) -> [String] {
        var candidates: [String] = []
        if let preferred = normalizedPowerShellExecutableName(preferredExecutableName) {
            candidates.append(preferred)
        }
        for fallback in ["powershell", "pwsh"] where !candidates.contains(fallback) {
            candidates.append(fallback)
        }
        return candidates
    }

    nonisolated static func powerShellExecutableName(inWindowsShellOutput output: String) -> String? {
        let normalized = output
            .lowercased()
            .replacingOccurrences(of: "\\", with: "/")
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'"))
        let tokens = normalized
            .components(separatedBy: separators)
            .compactMap { token -> String? in
                let executable = token
                    .split(separator: "/")
                    .last
                    .map(String.init)?
                    .replacingOccurrences(of: ".exe", with: "")
                return normalizedPowerShellExecutableName(executable)
            }

        if tokens.contains("pwsh") {
            return "pwsh"
        }
        if tokens.contains("powershell") {
            return "powershell"
        }
        return nil
    }

    private static func detectPowerShellExecutable(
        using client: SSHClient,
        preferredExecutableName: String?
    ) async -> String? {
        let marker = "__VVTERM_PWSH_OK__"
        for executable in powerShellExecutableCandidates(preferredExecutableName: preferredExecutableName) {
            if let output = await probe("cmd.exe /d /c where \(executable)", using: client),
               output.lowercased().contains(executable) {
                return executable
            }

            if let output = await probe("where \(executable)", using: client),
               output.lowercased().contains(executable) {
                return executable
            }

            let command = RemoteTerminalBootstrap.wrapPowerShellCommand("Write-Output '\(marker)'", executableName: executable)
            guard let output = await probe(command, using: client) else { continue }
            if output.contains(marker) {
                return executable
            }
        }
        return nil
    }

    private static func detectWindowsShell(using client: SSHClient) async -> RemoteWindowsShellDetection {
        if let output = await probe(#"reg query "HKLM\SOFTWARE\OpenSSH" /v DefaultShell"#, using: client) {
            let normalized = output.lowercased()
            if normalized.contains("powershell") || normalized.contains("pwsh") {
                return .powershell(
                    executableName: powerShellExecutableName(inWindowsShellOutput: output)
                )
            }
            if normalized.contains("cmd.exe") {
                return .cmd
            }
        }

        let powerShellMarker = "__VVTERM_ACTIVE_POWERSHELL__"
        if let output = await probe("Write-Output '\(powerShellMarker)'", using: client),
           output.contains(powerShellMarker) {
            return .powershell(executableName: nil)
        }

        let cmdMarker = "__VVTERM_ACTIVE_CMD__"
        if let output = await probe("for %I in (1) do @echo \(cmdMarker)", using: client),
           output.contains(cmdMarker) {
            return .cmd
        }

        return .unknown
    }

    nonisolated private static func normalizedPowerShellExecutableName(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value
            .lowercased()
            .replacingOccurrences(of: ".exe", with: "")
        if normalized == "pwsh" {
            return "pwsh"
        }
        if normalized == "powershell" {
            return "powershell"
        }
        return nil
    }

    private static func probe(_ command: String, using client: SSHClient) async -> String? {
        try? await client.execute(command, timeout: probeTimeout)
    }
}

private enum RemoteWindowsShellDetection: Equatable {
    case powershell(executableName: String?)
    case cmd
    case posix
    case unknown

    var powerShellExecutableName: String? {
        guard case .powershell(let executableName) = self else { return nil }
        return executableName
    }
}
