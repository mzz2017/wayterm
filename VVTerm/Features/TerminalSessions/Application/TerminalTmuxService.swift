import Foundation

protocol TerminalTmuxServicing: AnyObject, Sendable {
    func tmuxBackend(
        using client: SSHClient,
        preferred: TerminalMultiplexer
    ) async -> RemoteTmuxBackend?

    func tmuxInstallBackend(
        using executor: any RemoteCommandExecuting,
        preferred: TerminalMultiplexer
    ) async -> RemoteTmuxBackend?

    func isTmuxAvailable(
        using executor: any RemoteCommandExecuting,
        preferred: TerminalMultiplexer
    ) async -> Bool

    func listSessions(
        using executor: any RemoteCommandExecuting,
        backend: RemoteTmuxBackend
    ) async -> [RemoteTmuxSession]

    func prepareConfig(
        using executor: any RemoteCommandExecuting,
        terminalType: RemoteTerminalType,
        backend: RemoteTmuxBackend
    ) async

    func sendScript(_ script: String, using client: SSHClient, shellId: UUID) async

    func killSession(
        named sessionName: String,
        using executor: any RemoteCommandExecuting,
        preferred: TerminalMultiplexer
    ) async

    func cleanupLegacySessions(using executor: any RemoteCommandExecuting) async

    func cleanupDetachedSessions(
        deviceId: String,
        keeping sessionNames: Set<String>,
        using executor: any RemoteCommandExecuting,
        preferred: TerminalMultiplexer
    ) async

    func currentPath(sessionName: String, using executor: any RemoteCommandExecuting) async -> String?

    func startupAttachCommand(
        sessionName: String,
        workingDirectory: String,
        backend: RemoteTmuxBackend
    ) -> String

    func startupAttachExistingCommand(sessionName: String, backend: RemoteTmuxBackend) -> String

    func interactiveAttachCommand(
        sessionName: String,
        workingDirectory: String,
        backend: RemoteTmuxBackend
    ) -> String

    func interactiveAttachExistingCommand(sessionName: String, backend: RemoteTmuxBackend) -> String

    func installAndAttachScript(
        sessionName: String,
        workingDirectory: String,
        terminalType: RemoteTerminalType,
        backend: RemoteTmuxBackend
    ) -> String
}

extension RemoteTmuxManager: TerminalTmuxServicing {
    func prepareConfig(
        using executor: any RemoteCommandExecuting,
        terminalType: RemoteTerminalType,
        backend: RemoteTmuxBackend
    ) async {
        let explicitBackend: RemoteTmuxBackend? = backend
        await prepareConfig(
            using: executor,
            terminalType: terminalType,
            backend: explicitBackend
        )
    }

    nonisolated func startupAttachCommand(
        sessionName: String,
        workingDirectory: String,
        backend: RemoteTmuxBackend
    ) -> String {
        attachCommand(
            sessionName: sessionName,
            workingDirectory: workingDirectory,
            context: .startupExec,
            backend: backend
        )
    }

    nonisolated func startupAttachExistingCommand(sessionName: String, backend: RemoteTmuxBackend) -> String {
        attachExistingCommand(
            sessionName: sessionName,
            context: .startupExec,
            backend: backend
        )
    }

    nonisolated func interactiveAttachCommand(
        sessionName: String,
        workingDirectory: String,
        backend: RemoteTmuxBackend
    ) -> String {
        attachExecCommand(
            sessionName: sessionName,
            workingDirectory: workingDirectory,
            backend: backend
        )
    }

    nonisolated func interactiveAttachExistingCommand(sessionName: String, backend: RemoteTmuxBackend) -> String {
        attachExistingExecCommand(sessionName: sessionName, backend: backend)
    }
}
