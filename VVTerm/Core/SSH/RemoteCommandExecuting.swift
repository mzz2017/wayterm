import Foundation

protocol RemoteCommandExecuting: Sendable {
    func execute(_ command: String, timeout: Duration?) async throws -> String
    func remoteEnvironment(forceRefresh: Bool) async -> RemoteEnvironment
    func remoteTerminalType(forceRefresh: Bool) async -> RemoteTerminalType
}

extension RemoteCommandExecuting {
    func execute(_ command: String) async throws -> String {
        try await execute(command, timeout: nil)
    }

    func remoteEnvironment() async -> RemoteEnvironment {
        await remoteEnvironment(forceRefresh: false)
    }

    func remoteTerminalType() async -> RemoteTerminalType {
        await remoteTerminalType(forceRefresh: false)
    }
}

enum RemoteCommandFailure: Error, Equatable, Sendable {
    case unavailable
    case failed(String)
}

extension SSHClient: RemoteCommandExecuting {}
