import Foundation

@MainActor
final class RemoteFileServiceAccessCoordinator {
    private struct PendingDisconnect {
        let id: UUID
        let task: Task<Void, Never>
    }

    private let remoteFileServiceAdapter: SSHSFTPAdapter
    private var pendingDisconnects: [UUID: PendingDisconnect] = [:]

    #if DEBUG
    private var pendingDisconnectWaitDidFinishForTesting: (@MainActor (UUID) async -> Void)?
    #endif

    init(remoteFileServiceAdapter: SSHSFTPAdapter) {
        self.remoteFileServiceAdapter = remoteFileServiceAdapter
    }

    @discardableResult
    func disconnect(serverId: UUID) -> Task<Void, Never> {
        if let pending = pendingDisconnects[serverId] {
            return pending.task
        }

        let disconnectID = UUID()
        let task = Task { @MainActor [weak self, remoteFileServiceAdapter] in
            await remoteFileServiceAdapter.disconnect(serverId: serverId)
            if self?.pendingDisconnects[serverId]?.id == disconnectID {
                self?.pendingDisconnects.removeValue(forKey: serverId)
            }
        }
        pendingDisconnects[serverId] = PendingDisconnect(id: disconnectID, task: task)
        return task
    }

    func withRemoteFileService<T>(
        for server: Server,
        operation: @escaping (any RemoteFileService) async throws -> T
    ) async throws -> T {
        await waitForPendingDisconnect(serverId: server.id)
        return try await remoteFileServiceAdapter.withService(for: server, operation: operation)
    }

    private func waitForPendingDisconnect(serverId: UUID) async {
        while let pending = pendingDisconnects[serverId] {
            await pending.task.value
            if pendingDisconnects[serverId]?.id == pending.id {
                pendingDisconnects.removeValue(forKey: serverId)
            }
            #if DEBUG
            await pendingDisconnectWaitDidFinishForTesting?(serverId)
            #endif
        }
    }

    #if DEBUG
    func setPendingDisconnectWaitDidFinishForTesting(
        _ action: (@MainActor (UUID) async -> Void)?
    ) {
        pendingDisconnectWaitDidFinishForTesting = action
    }
    #endif
}
