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
        terminal: any TerminalConnectionSurface,
        logger: Logger,
        onAttempt: @MainActor @escaping (_ attempt: Int) -> Void,
        startupPlan: @MainActor @escaping () async -> (command: String?, skipTmuxLifecycle: Bool),
        registerShell: @MainActor @escaping (_ shell: ShellHandle, _ skipTmuxLifecycle: Bool) async -> Bool,
        onBeforeShellStart: @MainActor @escaping (_ cols: Int, _ rows: Int) async -> Void,
        onShellStarted: @MainActor @escaping (_ terminal: any TerminalConnectionSurface, _ shellId: UUID) async -> Void,
        onTitleChange: @MainActor @escaping (_ title: String) -> Void,
        shouldContinueStreaming: @MainActor @escaping (_ data: Data, _ terminal: any TerminalConnectionSurface) -> Bool,
        shouldResetClient: @escaping (_ error: SSHError) async -> Bool,
        onProcessExit: @MainActor @escaping () -> Void,
        onFailure: @MainActor @escaping (_ error: Error, _ terminal: any TerminalConnectionSurface) -> Void
    ) async {
        await run(
            terminal: terminal,
            logger: logger,
            onAttempt: { attempt in
                logger.info("Connecting to \(server.host)... (attempt \(attempt))")
                onAttempt(attempt)
            },
            connect: {
                _ = try await sshClient.connect(to: server, credentials: credentials)
            },
            startShell: { cols, rows, startupCommand in
                try await sshClient.startShell(
                    cols: cols,
                    rows: rows,
                    startupCommand: startupCommand
                )
            },
            closeShell: { shellId in
                await sshClient.closeShell(shellId)
            },
            startupPlan: startupPlan,
            registerShell: registerShell,
            onBeforeShellStart: onBeforeShellStart,
            onShellStarted: onShellStarted,
            onTitleChange: onTitleChange,
            shouldContinueStreaming: shouldContinueStreaming,
            shouldResetClient: shouldResetClient,
            resetConnection: {
                logger.warning("Resetting SSH client before retrying connection")
                await sshClient.disconnect()
            },
            onProcessExit: {
                onProcessExit()
            },
            onFailure: onFailure
        )
    }

    static func run(
        terminal: any TerminalConnectionSurface,
        logger: Logger? = nil,
        maxAttempts: Int = 3,
        onAttempt: @MainActor @escaping (_ attempt: Int) async -> Void,
        connect: @escaping () async throws -> Void,
        startShell: @escaping (_ cols: Int, _ rows: Int, _ startupCommand: String?) async throws -> ShellHandle,
        closeShell: @escaping (_ shellId: UUID) async -> Void,
        startupPlan: @MainActor @escaping () async -> (command: String?, skipTmuxLifecycle: Bool),
        registerShell: @MainActor @escaping (_ shell: ShellHandle, _ skipTmuxLifecycle: Bool) async -> Bool,
        onBeforeShellStart: @MainActor @escaping (_ cols: Int, _ rows: Int) async -> Void,
        onShellStarted: @MainActor @escaping (_ terminal: any TerminalConnectionSurface, _ shellId: UUID) async -> Void,
        onTitleChange: @MainActor @escaping (_ title: String) -> Void,
        shouldContinueStreaming: @MainActor @escaping (_ data: Data, _ terminal: any TerminalConnectionSurface) -> Bool,
        shouldResetClient: @escaping (_ error: SSHError) async -> Bool = { _ in false },
        resetConnection: @escaping () async -> Void = {},
        onProcessExit: @MainActor @escaping () async -> Void,
        onFailure: @MainActor @escaping (_ error: Error, _ terminal: any TerminalConnectionSurface) -> Void
    ) async {
        var titleParser = TerminalTitleSequenceParser()

        await runForTesting(
            logger: logger,
            maxAttempts: maxAttempts,
            onAttempt: { attempt in
                await onAttempt(attempt)
            },
            performAttempt: { _ in
                try await connect()
                try Task.checkCancellation()

                let size = terminal.connectionSurfaceSize()
                let cols = size?.columns ?? 80
                let rows = size?.rows ?? 24

                await onBeforeShellStart(cols, rows)
                let startup = await startupPlan()
                let shell = try await startShell(cols, rows, startup.command)

                guard !Task.isCancelled else {
                    await closeShell(shell.id)
                    return
                }

                let accepted = await registerShell(shell, startup.skipTmuxLifecycle)
                guard accepted else { return }
                await onShellStarted(terminal, shell.id)

                try Task.checkCancellation()
                for await data in shell.stream {
                    guard !Task.isCancelled else { break }
                    for title in titleParser.parse(data) {
                        onTitleChange(title)
                    }
                    let shouldContinue = shouldContinueStreaming(data, terminal)
                    if !shouldContinue { break }
                }

                try Task.checkCancellation()
                logger?.info("SSH shell ended")
                terminal.connectionSurfaceExited(0)
                await onProcessExit()
            },
            shouldResetClient: shouldResetClient,
            resetClient: resetConnection,
            onFailure: { error in
                onFailure(error, terminal)
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
