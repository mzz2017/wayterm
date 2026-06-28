import Foundation

@MainActor
protocol RemoteFileServiceAccessing {
    func withService<T: Sendable>(
        for server: Server,
        operation: @Sendable @escaping (any RemoteFileService) async throws -> T
    ) async throws -> T

    func disconnect(serverId: UUID) async
    func disconnectAll() async
}

struct MissingRemoteFileServiceAccess: RemoteFileServiceAccessing {
    func withService<T: Sendable>(
        for server: Server,
        operation: @Sendable @escaping (any RemoteFileService) async throws -> T
    ) async throws -> T {
        throw RemoteFileServiceAccessDependencyError.missingRemoteFileServiceAccess
    }

    func disconnect(serverId: UUID) async {}

    func disconnectAll() async {}
}

private enum RemoteFileServiceAccessDependencyError: LocalizedError {
    case missingRemoteFileServiceAccess

    var errorDescription: String? {
        "Remote file service access was not configured."
    }
}
