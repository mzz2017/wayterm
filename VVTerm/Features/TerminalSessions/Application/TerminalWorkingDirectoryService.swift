import Foundation

nonisolated protocol TerminalWorkingDirectoryApplying: Sendable {
    func apply(
        using client: SSHClient,
        shellId: UUID,
        workingDirectoryProvider: @escaping TerminalWorkingDirectoryService.WorkingDirectoryProvider
    ) async
}

nonisolated struct TerminalWorkingDirectoryService: Sendable {
    typealias WorkingDirectoryProvider = @MainActor @Sendable () -> String?

    func apply(
        using client: SSHClient,
        shellId: UUID,
        workingDirectoryProvider: @escaping WorkingDirectoryProvider
    ) async {
        guard let workingDirectory = await workingDirectoryProvider() else { return }
        let environment = await client.remoteEnvironment()
        guard let payload = Self.directoryChangePayload(
            for: workingDirectory,
            environment: environment
        ) else {
            return
        }

        try? await client.write(payload, to: shellId)
    }

    nonisolated static func directoryChangePayload(
        for workingDirectory: String,
        environment: RemoteEnvironment
    ) -> Data? {
        guard environment.supportsWorkingDirectoryRestore else { return nil }
        return RemoteTerminalBootstrap.directoryChangeCommand(
            for: workingDirectory,
            environment: environment
        ).data(using: .utf8)
    }
}

extension TerminalWorkingDirectoryService: TerminalWorkingDirectoryApplying {}
