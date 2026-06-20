//
//  TerminalConnectionRunner.swift
//  VVTerm
//
//  Owns terminal SSH connection attempt ordering and retry policy.
//

import Foundation
import os.log

enum TerminalConnectionRunner {
    static func run(
        server: Server,
        credentials: ServerCredentials,
        sshClient: SSHClient,
        terminal: GhosttyTerminalView,
        logger: Logger,
        onAttempt: @MainActor @escaping (_ attempt: Int) -> Void,
        startupPlan: @MainActor @escaping () async -> (command: String?, skipTmuxLifecycle: Bool),
        registerShell: @MainActor @escaping (_ shell: ShellHandle, _ skipTmuxLifecycle: Bool) async -> Bool,
        onBeforeShellStart: @MainActor @escaping (_ cols: Int, _ rows: Int) async -> Void,
        onShellStarted: @MainActor @escaping (_ terminal: GhosttyTerminalView, _ shellId: UUID) async -> Void,
        onTitleChange: @MainActor @escaping (_ title: String) -> Void,
        shouldContinueStreaming: @MainActor @escaping (_ data: Data, _ terminal: GhosttyTerminalView) -> Bool,
        shouldResetClient: @escaping (_ error: SSHError) async -> Bool,
        onProcessExit: @MainActor @escaping () -> Void,
        onFailure: @MainActor @escaping (_ error: Error, _ terminal: GhosttyTerminalView) -> Void
    ) async {
        var titleParser = TerminalTitleSequenceParser()

        await runForTesting(
            logger: logger,
            onAttempt: { attempt in
                await onAttempt(attempt)
            },
            performAttempt: { attempt in
                logger.info("Connecting to \(server.host)... (attempt \(attempt))")
                _ = try await sshClient.connect(to: server, credentials: credentials)
                try Task.checkCancellation()

                let size = await MainActor.run {
                    terminal.terminalSize()
                }
                let cols = Int(size?.columns ?? 80)
                let rows = Int(size?.rows ?? 24)

                await onBeforeShellStart(cols, rows)
                let startup = await startupPlan()
                let shell = try await sshClient.startShell(
                    cols: cols,
                    rows: rows,
                    startupCommand: startup.command
                )

                guard !Task.isCancelled else {
                    await sshClient.closeShell(shell.id)
                    return
                }

                let accepted = await registerShell(shell, startup.skipTmuxLifecycle)
                guard accepted else { return }
                await onShellStarted(terminal, shell.id)

                try Task.checkCancellation()
                for await data in shell.stream {
                    guard !Task.isCancelled else { break }
                    for title in titleParser.parse(data) {
                        await onTitleChange(title)
                    }
                    let shouldContinue = await shouldContinueStreaming(data, terminal)
                    if !shouldContinue { break }
                }

                try Task.checkCancellation()
                logger.info("SSH shell ended")
                // External backend: tell ghostty the session ended so it shows the
                // real "session ended" UI (same as a local process exit).
                await MainActor.run { terminal.externalExited(0) }
                await onProcessExit()
            },
            shouldResetClient: shouldResetClient,
            resetClient: {
                logger.warning("Resetting SSH client before retrying connection")
                await sshClient.disconnect()
            },
            onFailure: { error in
                await onFailure(error, terminal)
            }
        )
    }

    static func runForTesting(
        logger: Logger? = nil,
        maxAttempts: Int = 3,
        onAttempt: @escaping (_ attempt: Int) async -> Void,
        performAttempt: @escaping (_ attempt: Int) async throws -> Void,
        shouldResetClient: @escaping (_ error: SSHError) async -> Bool = { _ in false },
        resetClient: @escaping () async -> Void = {},
        onFailure: @escaping (_ error: Error) async -> Void
    ) async {
        var lastError: Error?

        for attempt in 1...maxAttempts {
            guard !Task.isCancelled else { return }
            await onAttempt(attempt)

            do {
                try await performAttempt(attempt)
                return
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                lastError = error
                logger?.error("SSH connection failed (attempt \(attempt)): \(error.localizedDescription)")

                // Do not retry deterministic failures (bad auth, host-key mismatch):
                // repeated failed auths trip sshd's penalty system.
                if let sshError = error as? SSHError, !sshError.isRetryable {
                    logger?.warning("Non-retryable SSH error; aborting retries")
                    break
                }

                if attempt < maxAttempts, let sshError = error as? SSHError {
                    let shouldReset = await shouldResetClient(sshError)
                    if shouldReset {
                        await resetClient()
                    }
                }

                if attempt < maxAttempts {
                    let delay = pow(2.0, Double(attempt - 1))
                    try? await Task.sleep(for: .seconds(delay))
                    continue
                }
            }
        }

        if let lastError {
            await onFailure(lastError)
        }
    }
}
