import Foundation

nonisolated private final class TerminalConnectionTeardownTaskRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var pendingCountsByServer: [UUID: Int] = [:]
    private var waitersByServer: [UUID: [CheckedContinuation<Void, Never>]] = [:]

    func track(_ operation: @escaping @Sendable () async -> Void, for serverId: UUID) {
        lock.lock()
        pendingCountsByServer[serverId, default: 0] += 1
        lock.unlock()

        Task.detached { [weak self] in
            await operation()
            self?.finishTask(for: serverId)
        }
    }

    func wait(for serverId: UUID) async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if pendingCountsByServer[serverId, default: 0] == 0 {
                lock.unlock()
                continuation.resume()
                return
            }
            waitersByServer[serverId, default: []].append(continuation)
            lock.unlock()
        }
    }

    func removeAll() {
        let waiters: [CheckedContinuation<Void, Never>]
        lock.lock()
        pendingCountsByServer.removeAll()
        waiters = waitersByServer.values.flatMap { $0 }
        waitersByServer.removeAll()
        lock.unlock()

        for waiter in waiters {
            waiter.resume()
        }
    }

    private func finishTask(for serverId: UUID) {
        let waiters: [CheckedContinuation<Void, Never>]

        lock.lock()
        let remainingCount = max(pendingCountsByServer[serverId, default: 1] - 1, 0)
        if remainingCount == 0 {
            pendingCountsByServer.removeValue(forKey: serverId)
            waiters = waitersByServer.removeValue(forKey: serverId) ?? []
        } else {
            pendingCountsByServer[serverId] = remainingCount
            waiters = []
        }
        lock.unlock()

        for waiter in waiters {
            waiter.resume()
        }
    }
}

nonisolated final class TerminalConnectionRegistry {
    private var runtimes: [TerminalEntityID: TerminalConnectionRuntime] = [:]
    private var serverIdsByEntity: [TerminalEntityID: UUID] = [:]
    private var statesByEntity: [TerminalEntityID: TerminalEntityConnectionState] = [:]
    private let teardownTasks = TerminalConnectionTeardownTaskRegistry()

    @MainActor
    var activeServerIds: Set<UUID> {
        Set(statesByEntity.compactMap { entityId, state in
            guard state.isConnected else { return nil }
            return serverIdsByEntity[entityId]
        })
    }

    @MainActor
    var hasStreamingEntity: Bool {
        statesByEntity.values.contains { $0.isConnected }
    }

    @MainActor
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

    @MainActor
    func isOpeningOrStreaming(_ entityId: TerminalEntityID) -> Bool {
        guard let state = statesByEntity[entityId] else { return false }
        return state.isConnected || state.isOpening
    }

    @MainActor
    func state(for entityId: TerminalEntityID) -> TerminalEntityConnectionState? {
        statesByEntity[entityId]
    }

    @MainActor
    func openingOrStreamingEntityIDs(for serverId: UUID) -> Set<TerminalEntityID> {
        Set(statesByEntity.compactMap { entityId, state in
            guard state.isConnected || state.isOpening else { return nil }
            guard serverIdsByEntity[entityId] == serverId else { return nil }
            return entityId
        })
    }

    @MainActor
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

    @MainActor
    func updateState(
        _ state: TerminalEntityConnectionState,
        for entityId: TerminalEntityID,
        serverId: UUID
    ) {
        serverIdsByEntity[entityId] = serverId
        statesByEntity[entityId] = state
    }

    @MainActor
    func runtime(for entityId: TerminalEntityID) -> TerminalConnectionRuntime? {
        runtimes[entityId]
    }

    @MainActor
    func removeRuntime(for entityId: TerminalEntityID, mode: ShellTeardownMode) {
        guard let runtime = runtimes.removeValue(forKey: entityId),
              let serverId = serverIdsByEntity.removeValue(forKey: entityId) else {
            return
        }

        teardownTasks.track({
            await runtime.close(mode: mode)
        }, for: serverId)
        statesByEntity[entityId] = .disconnected
    }

    @MainActor
    func discardRuntime(for entityId: TerminalEntityID) {
        runtimes.removeValue(forKey: entityId)
        serverIdsByEntity.removeValue(forKey: entityId)
        statesByEntity.removeValue(forKey: entityId)
    }

    @MainActor
    func waitForServerTeardown(_ serverId: UUID) async {
        await teardownTasks.wait(for: serverId)
    }

    @MainActor
    func removeAll() {
        runtimes.removeAll()
        serverIdsByEntity.removeAll()
        statesByEntity.removeAll()
        teardownTasks.removeAll()
    }
}
