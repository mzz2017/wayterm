import Foundation

nonisolated enum RemoteShellFamily: String, Hashable, Sendable {
    case posix
    case powershell
    case cmd
    case unknown
}

nonisolated struct RemoteShellProfile: Hashable, Sendable {
    let family: RemoteShellFamily
    let executableName: String?
    let shellName: String?

    var supportsPOSIXExecWrapper: Bool {
        family == .posix
    }

    var supportsPowerShellCommands: Bool {
        family == .powershell
    }

    var supportsOSC7Reporting: Bool {
        switch family {
        case .posix:
            return true
        case .powershell, .cmd, .unknown:
            return false
        }
    }

    nonisolated func launchPlan(startupCommand: String?, bundle: Bundle = .main) -> RemoteShellLaunchPlan {
        let trimmed = startupCommand?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch family {
        case .posix:
            guard !trimmed.isEmpty else {
                let script = RemoteTerminalBootstrap.prefixedPOSIXScript(
                    for: RemoteTerminalBootstrap.defaultLoginShellCommand(),
                    bundle: bundle
                )
                return .exec(RemoteTerminalBootstrap.wrapPOSIXShellCommand(script))
            }
            let script = RemoteTerminalBootstrap.prefixedPOSIXScript(for: trimmed, bundle: bundle)
            return .exec(RemoteTerminalBootstrap.wrapPOSIXShellCommand(script))
        case .powershell:
            guard !trimmed.isEmpty else {
                return .shell
            }
            let executable = executableName ?? "powershell"
            let script = RemoteTerminalBootstrap.prefixedPowerShellScript(for: trimmed, bundle: bundle)
            return .exec(RemoteTerminalBootstrap.wrapPowerShellCommand(script, executableName: executable))
        case .cmd:
            guard !trimmed.isEmpty else {
                return .shell
            }
            return .exec(RemoteTerminalBootstrap.wrapCmdCommand(trimmed))
        case .unknown:
            guard !trimmed.isEmpty else {
                return .shell
            }
            return .shell
        }
    }

    nonisolated func directoryChangeCommand(for path: String) -> String {
        switch family {
        case .posix:
            return RemoteTerminalBootstrap.posixDirectoryChangeCommand(for: path)
        case .powershell:
            return RemoteTerminalBootstrap.powerShellDirectoryChangeCommand(for: path)
        case .cmd:
            return RemoteTerminalBootstrap.cmdDirectoryChangeCommand(for: path)
        case .unknown:
            return "\n"
        }
    }

    static func posix(shellName: String?) -> RemoteShellProfile {
        RemoteShellProfile(family: .posix, executableName: shellName, shellName: shellName)
    }

    static func powershell(executableName: String?) -> RemoteShellProfile {
        let shellName = executableName?.lowercased()
        return RemoteShellProfile(family: .powershell, executableName: executableName, shellName: shellName)
    }

    static var cmd: RemoteShellProfile {
        RemoteShellProfile(family: .cmd, executableName: "cmd.exe", shellName: "cmd.exe")
    }

    static func unknown(shellName: String? = nil) -> RemoteShellProfile {
        RemoteShellProfile(family: .unknown, executableName: shellName, shellName: shellName)
    }
}

nonisolated struct RemoteEnvironment: Hashable, Sendable {
    let platform: RemotePlatform
    let shellProfile: RemoteShellProfile
    let activeShellName: String?
    let powerShellExecutable: String?

    nonisolated var supportsTmuxRuntime: Bool {
        if platform != .windows {
            return shellProfile.family == .posix
        }

        switch shellProfile.family {
        case .powershell, .cmd:
            return true
        case .posix, .unknown:
            return false
        }
    }

    nonisolated var supportsMoshRuntime: Bool {
        platform != .windows && shellProfile.family == .posix
    }

    nonisolated var supportsWorkingDirectoryRestore: Bool {
        switch shellProfile.family {
        case .posix, .powershell, .cmd:
            return true
        case .unknown:
            return false
        }
    }

    nonisolated static let fallbackPOSIX = RemoteEnvironment(
        platform: .linux,
        shellProfile: .posix(shellName: "sh"),
        activeShellName: "sh",
        powerShellExecutable: nil
    )
}
