import Foundation

protocol RemoteCommandExecuting: Sendable {
    func execute(_ command: String, timeout: Duration?) async throws -> String
    func remoteEnvironment(forceRefresh: Bool) async -> RemoteEnvironment
    func remoteTerminalType(forceRefresh: Bool) async -> RemoteTerminalType
}

enum RemoteCommandFailure: Error, Equatable, Sendable {
    case unavailable
    case failed(String)
}

extension SSHClient: RemoteCommandExecuting {}
