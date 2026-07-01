import Foundation

protocol TerminalMoshServicing: AnyObject, Sendable {
    func installMoshServer(using executor: any RemoteCommandExecuting) async throws
}

extension RemoteMoshManager: TerminalMoshServicing {}
