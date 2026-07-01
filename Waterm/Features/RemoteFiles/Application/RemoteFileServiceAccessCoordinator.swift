import Foundation

@MainActor
final class RemoteFileServiceAccessCoordinator {
    private struct PendingDisconnect {
        let id: UUID
        let task: Task<Void, Never>
    }

    private let remoteFileServiceAccess: any RemoteFileServiceAccessing
    private var pendingDisconnects: [UUID: PendingDisconnect] = [:]
    private var pendingDisconnectAll: PendingDisconnect?

    #if DEBUG
    private var pendingDisconnectWaitDidFinishForTesting: (@MainActor (UUID) async -> Void)?
    #endif

    init(remoteFileServiceAccess: any RemoteFileServiceAccessing) {
        self.remoteFileServiceAccess = remoteFileServiceAccess
    }

    @discardableResult
    func disconnect(
        serverId: UUID,
        waitingFor prerequisiteTasks: [Task<Void, Never>] = []
    ) -> Task<Void, Never> {
        if let pendingDisconnectAll {
            return pendingDisconnectAll.task
        }

        if let pending = pendingDisconnects[serverId] {
            return pending.task
        }

        let disconnectID = UUID()
        let task = Task { @MainActor [weak self, remoteFileServiceAccess, prerequisiteTasks] in
            for prerequisiteTask in prerequisiteTasks {
                await prerequisiteTask.value
            }
            await remoteFileServiceAccess.disconnect(serverId: serverId)
            if self?.pendingDisconnects[serverId]?.id == disconnectID {
                self?.pendingDisconnects.removeValue(forKey: serverId)
            }
        }
        pendingDisconnects[serverId] = PendingDisconnect(id: disconnectID, task: task)
        return task
    }

    @discardableResult
    func disconnectAll(
        waitingFor prerequisiteTasks: [Task<Void, Never>] = []
    ) -> Task<Void, Never> {
        if let pendingDisconnectAll {
            return pendingDisconnectAll.task
        }

        let disconnectID = UUID()
        let pendingDisconnectTasks = pendingDisconnects.values.map(\.task)
        let task = Task { @MainActor [weak self, remoteFileServiceAccess, prerequisiteTasks, pendingDisconnectTasks] in
            for prerequisiteTask in prerequisiteTasks {
                await prerequisiteTask.value
            }
            for pendingDisconnectTask in pendingDisconnectTasks {
                await pendingDisconnectTask.value
            }
            await remoteFileServiceAccess.disconnectAll()
            if self?.pendingDisconnectAll?.id == disconnectID {
                self?.pendingDisconnectAll = nil
            }
        }
        pendingDisconnectAll = PendingDisconnect(id: disconnectID, task: task)
        return task
    }

    func withRemoteFileService<T: Sendable>(
        for server: Server,
        operation: @Sendable @escaping (any RemoteFileService) async throws -> T
    ) async throws -> T {
        await waitForPendingDisconnectAll()
        await waitForPendingDisconnect(serverId: server.id)
        return try await remoteFileServiceAccess.withService(for: server, operation: operation)
    }

    private func waitForPendingDisconnectAll() async {
        while let pending = pendingDisconnectAll {
            await pending.task.value
            if pendingDisconnectAll?.id == pending.id {
                pendingDisconnectAll = nil
            }
        }
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
