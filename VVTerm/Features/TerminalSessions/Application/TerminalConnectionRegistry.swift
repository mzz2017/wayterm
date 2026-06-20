import Foundation

@MainActor
final class TerminalConnectionRegistry {
    private var runtimes: [TerminalEntityID: TerminalConnectionRuntime] = [:]
    private var serverIdsByEntity: [TerminalEntityID: UUID] = [:]
    private var statesByEntity: [TerminalEntityID: TerminalEntityConnectionState] = [:]
    private var teardownTasksByServer: [UUID: [UUID: Task<Void, Never>]] = [:]

    var activeServerIds: Set<UUID> {
        Set(statesByEntity.compactMap { entityId, state in
            guard state.isConnected else { return nil }
            return serverIdsByEntity[entityId]
        })
    }

    func hasActiveEntity(
        for serverId: UUID,
        excluding excludedEntityId: TerminalEntityID
    ) -> Bool {
        statesByEntity.contains { entityId, state in
            entityId != excludedEntityId
                && state.isConnected
                && serverIdsByEntity[entityId] == serverId
        }
    }

    func isOpeningOrStreaming(_ entityId: TerminalEntityID) -> Bool {
        guard let state = statesByEntity[entityId] else { return false }
        return state.isConnected || state.isOpening
    }

    func register(
        _ runtime: TerminalConnectionRuntime,
        for entityId: TerminalEntityID,
        serverId: UUID
    ) {
        runtimes[entityId] = runtime
        serverIdsByEntity[entityId] = serverId
        if statesByEntity[entityId] == nil {
            statesByEntity[entityId] = .idle
        }
    }

    func updateState(
        _ state: TerminalEntityConnectionState,
        for entityId: TerminalEntityID,
        serverId: UUID
    ) {
        serverIdsByEntity[entityId] = serverId
        statesByEntity[entityId] = state
    }

    func runtime(for entityId: TerminalEntityID) -> TerminalConnectionRuntime? {
        runtimes[entityId]
    }

    func removeRuntime(for entityId: TerminalEntityID, mode: ShellTeardownMode) {
        guard let runtime = runtimes.removeValue(forKey: entityId),
              let serverId = serverIdsByEntity.removeValue(forKey: entityId) else {
            return
        }

        let task = Task {
            await runtime.close(mode: mode)
        }
        statesByEntity[entityId] = .disconnected
        trackTeardownTask(task, for: serverId)
    }

    func waitForServerTeardown(_ serverId: UUID) async {
        while let tasksById = teardownTasksByServer[serverId], !tasksById.isEmpty {
            for task in tasksById.values {
                await task.value
            }
        }
    }

    private func trackTeardownTask(_ task: Task<Void, Never>, for serverId: UUID) {
        let taskId = UUID()
        teardownTasksByServer[serverId, default: [:]][taskId] = task

        Task { @MainActor [weak self] in
            await task.value
            guard let self else { return }
            self.teardownTasksByServer[serverId]?.removeValue(forKey: taskId)
            if self.teardownTasksByServer[serverId]?.isEmpty == true {
                self.teardownTasksByServer.removeValue(forKey: serverId)
            }
        }
    }

    func removeAll() {
        runtimes.removeAll()
        serverIdsByEntity.removeAll()
        statesByEntity.removeAll()
        teardownTasksByServer.removeAll()
    }
}
