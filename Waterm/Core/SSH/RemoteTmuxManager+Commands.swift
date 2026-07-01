import Foundation

extension RemoteTmuxManager {
    nonisolated func configWriteExecutionCommand(
        terminalType: RemoteTerminalType,
        backend: RemoteTmuxBackend = .unixTmux
    ) -> String {
        let configWrite = configWriteCommand(terminalType: terminalType, backend: backend)
        return backend.isWindows
            ? configWrite
            : "sh -lc \(RemoteTerminalBootstrap.shellQuoted(configWrite))"
    }

    nonisolated func attachCommand(
        sessionName: String,
        workingDirectory: String,
        context: CommandContext = .startupExec,
        backend: RemoteTmuxBackend = .unixTmux
    ) -> String {
        if case .zmx = backend {
            let zmxContext: RemoteZmxCommandBuilder.CommandContext =
                (context == .startupExec) ? .startupExec : .interactiveShell
            return zmxBuilder.attachCommand(sessionName: sessionName, context: zmxContext)
        }
        let body = attachOrCreateBody(
            sessionName: sessionName,
            workingDirectory: workingDirectory,
            context: context,
            backend: backend
        )
        return commandString(for: body, context: context, backend: backend)
    }

    nonisolated func attachExistingCommand(
        sessionName: String,
        context: CommandContext = .startupExec,
        backend: RemoteTmuxBackend = .unixTmux
    ) -> String {
        if case .zmx = backend {
            let zmxContext: RemoteZmxCommandBuilder.CommandContext =
                (context == .startupExec) ? .startupExec : .interactiveShell
            return zmxBuilder.attachCommand(sessionName: sessionName, context: zmxContext)
        }
        let body = attachExistingBody(
            sessionName: sessionName,
            missingCommand: missingSessionCommand(for: context, backend: backend),
            backend: backend
        )
        return commandString(for: body, context: context, backend: backend)
    }

    nonisolated func attachExistingExecCommand(
        sessionName: String,
        backend: RemoteTmuxBackend = .unixTmux
    ) -> String {
        attachExistingCommand(sessionName: sessionName, context: .interactiveShell, backend: backend)
    }

    nonisolated func attachExecCommand(
        sessionName: String,
        workingDirectory: String,
        backend: RemoteTmuxBackend = .unixTmux
    ) -> String {
        attachCommand(
            sessionName: sessionName,
            workingDirectory: workingDirectory,
            context: .interactiveShell,
            backend: backend
        )
    }

    nonisolated func installAndAttachScript(
        sessionName: String,
        workingDirectory: String,
        terminalType: RemoteTerminalType,
        backend: RemoteTmuxBackend = .unixTmux
    ) -> String {
        if case .zmx = backend {
            // No remote installer for zmx; just attach (assumes zmx present).
            return zmxBuilder.attachCommand(sessionName: sessionName, context: .startupExec)
        }

        if backend.isWindows {
            return windowsInstallAndAttachScript(
                sessionName: sessionName,
                workingDirectory: workingDirectory,
                terminalType: terminalType,
                backend: backend
            )
        }

        let attach = attachCommand(
            sessionName: sessionName,
            workingDirectory: workingDirectory,
            context: .startupExec,
            backend: backend
        )
        let configWrite = configWriteCommand(terminalType: terminalType, backend: backend)

        let body = """
        \(RemoteTerminalBootstrap.shellPathExport());
        \(configWrite);
        if command -v tmux >/dev/null 2>&1; then \(attach); fi;
        if command -v sudo >/dev/null 2>&1; then SUDO="sudo"; else SUDO=""; fi;
        OS_NAME="$(uname -s)";
        if [ "$OS_NAME" = "Darwin" ]; then
          if command -v brew >/dev/null 2>&1; then
            brew install tmux;
          elif command -v port >/dev/null 2>&1; then
            $SUDO port install tmux;
          else
            echo "No supported package manager found for macOS.";
          fi;
        elif [ "$OS_NAME" = "Linux" ]; then
          if command -v apt-get >/dev/null 2>&1; then
            $SUDO apt-get update && $SUDO apt-get install -y tmux;
          elif command -v dnf >/dev/null 2>&1; then
            $SUDO dnf install -y tmux;
          elif command -v yum >/dev/null 2>&1; then
            $SUDO yum install -y tmux;
          elif command -v pacman >/dev/null 2>&1; then
            $SUDO pacman -Sy --noconfirm tmux;
          elif command -v apk >/dev/null 2>&1; then
            $SUDO apk add tmux;
          elif command -v zypper >/dev/null 2>&1; then
            $SUDO zypper -n install tmux;
          elif command -v xbps-install >/dev/null 2>&1; then
            $SUDO xbps-install -Sy tmux;
          elif command -v opkg >/dev/null 2>&1; then
            $SUDO opkg update && $SUDO opkg install tmux;
          elif command -v emerge >/dev/null 2>&1; then
            $SUDO emerge app-misc/tmux;
          elif command -v pkg >/dev/null 2>&1; then
            $SUDO pkg install -y tmux;
          else
            echo "No supported package manager found for Linux.";
          fi;
        else
          echo "Unsupported OS: $OS_NAME";
        fi;
        if command -v tmux >/dev/null 2>&1; then \(attach); else echo "tmux installation failed."; fi
        """
        return "sh -lc \(RemoteTerminalBootstrap.shellQuoted(body))"
    }

    nonisolated func tmuxAvailabilityProbeCommand(okMarker: String) -> String {
        let body = """
        \(RemoteTerminalBootstrap.shellPathExport());
        WATERM_TMUX_BIN="";
        if command -v tmux >/dev/null 2>&1; then
          WATERM_TMUX_BIN="$(command -v tmux 2>/dev/null)";
        fi;
        if [ -z "$WATERM_TMUX_BIN" ]; then
          for candidate in /usr/bin/tmux /bin/tmux /usr/local/bin/tmux /opt/local/bin/tmux /snap/bin/tmux; do
            if [ -x "$candidate" ]; then
              WATERM_TMUX_BIN="$candidate";
              break;
            fi;
          done;
        fi;
        if [ -n "$WATERM_TMUX_BIN" ] && "$WATERM_TMUX_BIN" -V >/dev/null 2>&1; then
          printf '\(okMarker)';
        else
          printf '__WATERM_TMUX_NO__';
        fi
        """
        return "sh -c \(RemoteTerminalBootstrap.shellQuoted(body))"
    }

    nonisolated func windowsPsmuxAvailabilityProbeCommand(
        commandName: String,
        backend: RemoteTmuxBackend,
        requirePsmuxExtension: Bool
    ) -> String {
        let marker = "__WATERM_TMUX_OK__:\(commandName)"
        let script = """
        $cmd = Get-Command \(powerShellQuoted(commandName)) -ErrorAction SilentlyContinue
        if ($cmd) {
          & $cmd.Source -V *> $null
          if ($LASTEXITCODE -eq 0) {
            $watermCommands = (& $cmd.Source list-commands 2>$null) -join "`n"
            if (-not \(requirePsmuxExtension ? "$true" : "$false") -or $watermCommands.Contains('dump-state') -or $watermCommands.Contains('claim-session')) {
              Write-Output \(powerShellQuoted(marker))
            }
          }
        }
        """
        return windowsShellCommand(powerShellScript: script, backend: backend)
    }

    nonisolated func listSessionCommands(backend: RemoteTmuxBackend) -> [String] {
        switch backend {
        case .unixTmux:
            let tmux = tmuxCommand(includeUTF8: false, includeConfig: false)
            let bodies = [
                "\(RemoteTerminalBootstrap.shellPathExport()); \(tmux) list-sessions -F '#{session_name} #{session_attached} #{session_windows}' 2>/dev/null",
                "\(RemoteTerminalBootstrap.shellPathExport()); \(tmux) list-sessions -F '#{session_name} #{session_attached}' 2>/dev/null",
                "\(RemoteTerminalBootstrap.shellPathExport()); \(tmux) list-sessions 2>/dev/null"
            ]
            return bodies.map { "sh -lc \(RemoteTerminalBootstrap.shellQuoted($0))" }

        case .windowsPsmux(let commandName, _, _):
            return [
                windowsPsmuxListSessionsCommand(commandName: commandName, format: "#{session_name} #{session_attached} #{session_windows}", backend: backend),
                windowsPsmuxListSessionsCommand(commandName: commandName, format: "#{session_name} #{session_attached}", backend: backend),
                windowsShellCommand(
                    powerShellScript: "& \(powerShellQuoted(commandName)) list-sessions 2>$null",
                    backend: backend
                )
            ]

        case .zmx:
            // zmx listing is handled in listSessions(using:backend:) via zmxBuilder.
            return [zmxBuilder.listSessionsCommand()]
        }
    }

    nonisolated func killSessionCommand(named sessionName: String, backend: RemoteTmuxBackend) -> String {
        switch backend {
        case .unixTmux:
            let quoted = RemoteTerminalBootstrap.shellQuoted(sessionName)
            let tmux = tmuxCommand(includeUTF8: false, includeConfig: false)
            let body = "\(RemoteTerminalBootstrap.shellPathExport()); \(tmux) kill-session -t \(quoted) 2>/dev/null || true"
            return "sh -lc \(RemoteTerminalBootstrap.shellQuoted(body))"

        case .windowsPsmux(let commandName, _, _):
            let script = "& \(powerShellQuoted(commandName)) kill-session -t \(powerShellQuoted(sessionName)) 2>$null"
            return windowsShellCommand(powerShellScript: script, backend: backend)

        case .zmx:
            return zmxBuilder.killSessionCommand(named: sessionName)
        }
    }

    nonisolated func currentPathCommand(sessionName: String, backend: RemoteTmuxBackend) -> String {
        switch backend {
        case .unixTmux:
            let quotedSession = RemoteTerminalBootstrap.shellQuoted(sessionName)
            let tmux = tmuxCommand(includeUTF8: false, includeConfig: false)
            let body = "\(RemoteTerminalBootstrap.shellPathExport()); \(tmux) list-panes -t \(quotedSession) -F '#{pane_current_path}' 2>/dev/null | head -n 1"
            return "sh -lc \(RemoteTerminalBootstrap.shellQuoted(body))"

        case .windowsPsmux(let commandName, _, _):
            let script = "& \(powerShellQuoted(commandName)) list-panes -t \(powerShellQuoted(sessionName)) -F '#{pane_current_path}' 2>$null | Select-Object -First 1"
            return windowsShellCommand(powerShellScript: script, backend: backend)

        case .zmx:
            // zmx has no list-panes; current path is resolved via the shell, not here.
            return ""
        }
    }

    nonisolated private func shellDirectoryArgument(_ value: String) -> String {
        if value == "~" {
            return "$HOME"
        }
        let escaped = value.replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    nonisolated private func commandString(for body: String, context: CommandContext) -> String {
        commandString(for: body, context: context, backend: .unixTmux)
    }

    nonisolated private func commandString(
        for body: String,
        context: CommandContext,
        backend: RemoteTmuxBackend
    ) -> String {
        if backend.isWindows {
            return body
        }

        switch context {
        case .startupExec:
            return body
        case .interactiveShell:
            return "sh -lc \(RemoteTerminalBootstrap.shellQuoted(body))"
        }
    }

    nonisolated private func missingSessionCommand(for context: CommandContext) -> String {
        missingSessionCommand(for: context, backend: .unixTmux)
    }

    nonisolated private func missingSessionCommand(
        for context: CommandContext,
        backend: RemoteTmuxBackend
    ) -> String {
        if backend.isWindows {
            switch context {
            case .startupExec:
                return windowsDefaultShellCommand(backend: backend)
            case .interactiveShell:
                return ""
            }
        }

        switch context {
        case .startupExec:
            return "exec \"${SHELL:-/bin/sh}\" -l"
        case .interactiveShell:
            return ":"
        }
    }

    nonisolated private func attachOrCreateBody(
        sessionName: String,
        workingDirectory: String,
        context: CommandContext = .startupExec,
        backend: RemoteTmuxBackend = .unixTmux
    ) -> String {
        if case .windowsPsmux = backend {
            return windowsAttachOrCreateCommand(
                sessionName: sessionName,
                workingDirectory: workingDirectory,
                backend: backend
            )
        }

        let createCommand = createSessionCommand(
            sessionName: sessionName,
            workingDirectory: workingDirectory,
            backend: backend
        )
        return attachExistingBody(
            sessionName: sessionName,
            missingCommand: createCommand,
            backend: backend
        )
    }

    nonisolated private func attachExistingBody(
        sessionName: String,
        missingCommand: String,
        backend: RemoteTmuxBackend = .unixTmux
    ) -> String {
        if case .windowsPsmux = backend {
            return windowsAttachExistingCommand(
                sessionName: sessionName,
                missingCommand: missingCommand,
                backend: backend
            )
        }

        let exactSession = RemoteTerminalBootstrap.shellQuoted("=\(sessionName)")
        let plainSession = RemoteTerminalBootstrap.shellQuoted(sessionName)
        let tmuxProbe = tmuxCommand(includeUTF8: false, includeConfig: false)
        let tmuxAttach = tmuxCommand(includeUTF8: true, includeConfig: true)
        let tmuxSource = tmuxCommand(includeUTF8: false, includeConfig: false)

        return """
        \(RemoteTerminalBootstrap.shellPathExport()); \
        if \(tmuxProbe) has-session -t \(exactSession) 2>/dev/null; then \
        \(tmuxSource) source-file \(configPath) >/dev/null 2>&1 || true; exec \(tmuxAttach) attach-session -t \(exactSession); \
        elif \(tmuxProbe) has-session -t \(plainSession) 2>/dev/null; then \
        \(tmuxSource) source-file \(configPath) >/dev/null 2>&1 || true; exec \(tmuxAttach) attach-session -t \(plainSession); \
        else \(missingCommand); fi
        """
    }

    nonisolated private func createSessionCommand(
        sessionName: String,
        workingDirectory: String,
        backend: RemoteTmuxBackend = .unixTmux
    ) -> String {
        if case .windowsPsmux = backend {
            return windowsCreateSessionCommand(
                sessionName: sessionName,
                workingDirectory: workingDirectory,
                backend: backend
            )
        }

        let escapedDir = shellDirectoryArgument(workingDirectory)
        let escapedSession = RemoteTerminalBootstrap.shellQuoted(sessionName)
        let tmux = tmuxCommand(includeUTF8: true, includeConfig: true)
        return "exec \(tmux) new-session -A -s \(escapedSession) -c \(escapedDir)"
    }

    nonisolated private func tmuxCommand(
        includeUTF8: Bool,
        includeConfig: Bool
    ) -> String {
        var parts = ["tmux"]
        if includeUTF8 {
            parts.append("-u")
        }
        if includeConfig {
            parts.append("-f \(configPath)")
        }
        return parts.joined(separator: " ")
    }

    nonisolated private func windowsPsmuxListSessionsCommand(
        commandName: String,
        format: String,
        backend: RemoteTmuxBackend
    ) -> String {
        windowsShellCommand(
            powerShellScript: "& \(powerShellQuoted(commandName)) list-sessions -F \(powerShellQuoted(format)) 2>$null",
            backend: backend
        )
    }

    nonisolated private func windowsAttachOrCreateCommand(
        sessionName: String,
        workingDirectory: String,
        backend: RemoteTmuxBackend
    ) -> String {
        windowsShellCommand(
            powerShellScript: windowsAttachOrCreatePowerShell(
                sessionName: sessionName,
                workingDirectory: workingDirectory,
                backend: backend
            ),
            backend: backend
        )
    }

    nonisolated private func windowsAttachExistingCommand(
        sessionName: String,
        missingCommand: String,
        backend: RemoteTmuxBackend
    ) -> String {
        windowsShellCommand(
            powerShellScript: windowsAttachExistingPowerShell(
                sessionName: sessionName,
                missingCommand: missingCommand,
                backend: backend
            ),
            backend: backend
        )
    }

    nonisolated private func windowsAttachOrCreatePowerShell(
        sessionName: String,
        workingDirectory: String,
        backend: RemoteTmuxBackend,
        commandExpression: String? = nil
    ) -> String {
        let createCommand = windowsCreateSessionPowerShell(
            sessionName: sessionName,
            workingDirectory: workingDirectory,
            backend: backend,
            commandExpression: commandExpression
        )
        return windowsAttachExistingPowerShell(
            sessionName: sessionName,
            missingCommand: createCommand,
            backend: backend,
            commandExpression: commandExpression
        )
    }

    nonisolated private func windowsAttachExistingPowerShell(
        sessionName: String,
        missingCommand: String,
        backend: RemoteTmuxBackend,
        commandExpression: String? = nil
    ) -> String {
        guard case .windowsPsmux(let commandName, _, _) = backend else { return missingCommand }
        let psmuxExpression = commandExpression ?? powerShellQuoted(commandName)
        return """
        $watermPsmux = \(psmuxExpression)
        $watermConfig = \(windowsConfigPathPowerShellExpression())
        $watermSession = \(powerShellQuoted(sessionName))
        & $watermPsmux has-session -t $watermSession 2>$null
        if ($LASTEXITCODE -eq 0) {
          & $watermPsmux -f $watermConfig source-file $watermConfig 2>$null
          & $watermPsmux -u -f $watermConfig attach-session -d -t $watermSession
        } else {
        \(indentPowerShell(missingCommand, spaces: 2))
        }
        """
    }

    nonisolated private func windowsCreateSessionCommand(
        sessionName: String,
        workingDirectory: String,
        backend: RemoteTmuxBackend
    ) -> String {
        windowsShellCommand(
            powerShellScript: windowsCreateSessionPowerShell(
                sessionName: sessionName,
                workingDirectory: workingDirectory,
                backend: backend
            ),
            backend: backend
        )
    }

    nonisolated private func windowsCreateSessionPowerShell(
        sessionName: String,
        workingDirectory: String,
        backend: RemoteTmuxBackend,
        commandExpression: String? = nil
    ) -> String {
        guard case .windowsPsmux(let commandName, _, _) = backend else { return "" }
        let psmuxExpression = commandExpression ?? powerShellQuoted(commandName)
        return """
        $watermPsmux = \(psmuxExpression)
        $watermConfig = \(windowsConfigPathPowerShellExpression())
        $watermSession = \(powerShellQuoted(sessionName))
        $watermWorkingDirectory = \(windowsWorkingDirectoryExpression(workingDirectory))
        & $watermPsmux -u -f $watermConfig new-session -A -s $watermSession -c $watermWorkingDirectory
        """
    }

    nonisolated private func windowsDefaultShellCommand(backend: RemoteTmuxBackend) -> String {
        guard case .windowsPsmux(_, let shellFamily, let powerShellExecutable) = backend else { return "" }
        switch shellFamily {
        case .powershell:
            let executable = powerShellExecutable ?? "powershell"
            return "& \(powerShellQuoted(executable))"
        case .cmd:
            return "cmd.exe"
        case .unknown, .posix:
            if let executable = powerShellExecutable {
                return "& \(powerShellQuoted(executable))"
            }
            return ""
        }
    }

    nonisolated private func configWriteCommand(
        terminalType: RemoteTerminalType,
        backend: RemoteTmuxBackend = .unixTmux
    ) -> String {
        if backend.isWindows {
            return windowsConfigWriteCommand(terminalType: terminalType, backend: backend)
        }

        let lines = configLines(terminalType: terminalType, includeWheelBindings: true)
        let quotedLines = lines.map { "\"\(escapeForDoubleQuotes($0))\"" }.joined(separator: " ")
        return "mkdir -p \(configDirectory); printf '%s\\n' \(quotedLines) > \(configPath)"
    }

    nonisolated private func configLines(
        terminalType: RemoteTerminalType,
        includeWheelBindings: Bool
    ) -> [String] {
        let themeName = UserDefaults.standard.string(forKey: CloudKitSyncConstants.terminalThemeNameKey) ?? "Aizen Dark"
        let modeStyle = ThemeColorParser.tmuxModeStyle(for: themeName)
        var lines = [
            "# Waterm tmux configuration",
            "# Auto-generated by Waterm - changes will be overwritten",
            "",
            "# Preserve true-color and terminal metadata when attaching",
        ]
        lines.append(contentsOf: RemoteTerminalBootstrap.tmuxArrayOptionCommands(
            option: "update-environment",
            values: RemoteTerminalBootstrap.tmuxUpdateEnvironmentVariables()
        ))
        lines.append(contentsOf: RemoteTerminalBootstrap.tmuxEnvironmentCommands())
        lines.append(contentsOf: RemoteTerminalBootstrap.tmuxArrayOptionCommands(
            option: "terminal-features",
            values: ["*:hyperlinks"]
        ))
        lines.append(contentsOf: RemoteTerminalBootstrap.tmuxArrayOptionCommands(
            option: "terminal-overrides",
            values: ["\(terminalType.rawValue):RGB"]
        ))
        lines.append(contentsOf: [
            "",
            "# Allow OSC sequences to pass through (title updates, etc.)",
            "set -g allow-passthrough on",
            "",
            "# Publish the active pane title to the outer Waterm terminal",
            "set -g allow-set-title on",
            "set -g set-titles on",
            "set -g set-titles-string \"#{pane_title}\"",
            "",
            "# Hide status bar",
            "set -g status off",
            "",
            "# Increase scrollback buffer",
            "set -g history-limit 10000",
            "",
            "# Enable mouse support",
            "set -g mouse on",
            "",
            "# Set default terminal with true color support",
            "set -g default-terminal \"\(terminalType.rawValue)\"",
            "",
            "# Selection highlighting in copy-mode (from theme: \(themeName))",
            "set -g mode-style \"\(modeStyle)\""
        ])

        if includeWheelBindings {
            lines.append(contentsOf: [
                "",
                "# Smart mouse scroll: copy-mode at shell, passthrough in TUI apps",
                "bind -n WheelUpPane if -F '#{||:#{mouse_any_flag},#{alternate_on}}' 'send-keys -M' 'copy-mode -eH; send-keys -M'",
                "bind -n WheelDownPane if -F '#{||:#{mouse_any_flag},#{alternate_on}}' 'send-keys -M' 'send-keys -M'"
            ])
        } else {
            lines.append(contentsOf: [
                "",
                "# Use psmux's native scroll behavior on Windows"
            ])
        }

        return lines
    }

    nonisolated private func windowsConfigWriteCommand(
        terminalType: RemoteTerminalType,
        backend: RemoteTmuxBackend
    ) -> String {
        windowsShellCommand(
            powerShellScript: windowsConfigWritePowerShell(terminalType: terminalType),
            backend: backend
        )
    }

    nonisolated private func windowsConfigWritePowerShell(
        terminalType: RemoteTerminalType
    ) -> String {
        let lines = configLines(terminalType: terminalType, includeWheelBindings: false)
        let content = lines.joined(separator: "\n") + "\n"
        return """
        $watermConfigDirectory = \(windowsConfigDirectoryPowerShellExpression())
        $watermConfigPath = \(windowsConfigPathPowerShellExpression())
        New-Item -ItemType Directory -Force -Path $watermConfigDirectory | Out-Null
        @'
        \(content)'@ | Set-Content -Encoding UTF8 -NoNewline -Path $watermConfigPath
        """
    }

    nonisolated private func windowsInstallAndAttachScript(
        sessionName: String,
        workingDirectory: String,
        terminalType: RemoteTerminalType,
        backend: RemoteTmuxBackend
    ) -> String {
        let configWrite = windowsConfigWritePowerShell(terminalType: terminalType)
        let attach = windowsAttachOrCreatePowerShell(
            sessionName: sessionName,
            workingDirectory: workingDirectory,
            backend: backend,
            commandExpression: "$watermPsmuxCommand.Source"
        )
        let script = """
        \(configWrite)
        function Get-WatermPsmuxCommand {
          $cmd = Get-Command psmux -ErrorAction SilentlyContinue
          if (-not $cmd) {
            $cmd = Get-Command pmux -ErrorAction SilentlyContinue
          }
          return $cmd
        }
        $watermPsmuxCommand = Get-WatermPsmuxCommand
        $watermPsmuxInstalled = $null -ne $watermPsmuxCommand
        if (-not $watermPsmuxInstalled -and (Get-Command winget -ErrorAction SilentlyContinue)) {
          winget install --id marlocarlo.psmux --accept-package-agreements --accept-source-agreements
          $watermPsmuxCommand = Get-WatermPsmuxCommand
          $watermPsmuxInstalled = $null -ne $watermPsmuxCommand
        }
        if (-not $watermPsmuxInstalled -and (Get-Command scoop -ErrorAction SilentlyContinue)) {
          scoop bucket add psmux https://github.com/psmux/scoop-psmux
          scoop install psmux
          $watermPsmuxCommand = Get-WatermPsmuxCommand
          $watermPsmuxInstalled = $null -ne $watermPsmuxCommand
        }
        if (-not $watermPsmuxInstalled -and (Get-Command choco -ErrorAction SilentlyContinue)) {
          choco install psmux -y
          $watermPsmuxCommand = Get-WatermPsmuxCommand
          $watermPsmuxInstalled = $null -ne $watermPsmuxCommand
        }
        if (-not $watermPsmuxInstalled -and (Get-Command cargo -ErrorAction SilentlyContinue)) {
          cargo install psmux
          $watermPsmuxCommand = Get-WatermPsmuxCommand
          $watermPsmuxInstalled = $null -ne $watermPsmuxCommand
        }
        if ($watermPsmuxInstalled) {
        \(indentPowerShell(attach, spaces: 2))
        } else {
          Write-Output 'psmux installation failed or no supported package manager was found.'
        }
        """
        return windowsShellCommand(powerShellScript: script, backend: backend)
    }
}
