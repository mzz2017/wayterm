import Foundation

@MainActor
final class ServerConnectionLifecycleCoordinator {
    typealias RemoteFilesDisconnectAction = @MainActor (UUID) -> Task<Void, Never>
    typealias StatsDisconnectAction = @MainActor (UUID) async -> Void
    typealias FileTabsDisconnectAction = @MainActor (UUID) -> Void
    typealias TerminalDisconnectAction = @MainActor (UUID) async -> Void
    typealias DeletionTerminalDisconnectAction = @MainActor @Sendable (UUID) async -> Void

    static let shared = ServerConnectionLifecycleCoordinator()

    private struct DisconnectRequest {
        let serverId: UUID
        let task: Task<Void, Never>
        var onCompleted: [@MainActor () -> Void]
    }

    private struct ResourceDisconnects {
        var disconnectRemoteFiles: RemoteFilesDisconnectAction = { _ in Task {} }
        var disconnectStats: StatsDisconnectAction = { _ in }
        var disconnectFileTabs: FileTabsDisconnectAction?
    }

    private var disconnectRequests: [UUID: DisconnectRequest] = [:]
    private var disconnectRequestByServer: [UUID: UUID] = [:]
    private var resourceDisconnects = ResourceDisconnects()

    var pendingDisconnectRequestIDs: Set<UUID> {
        Set(disconnectRequests.keys)
    }

    func configureResourceDisconnects(
        disconnectRemoteFiles: @escaping RemoteFilesDisconnectAction,
        disconnectStats: @escaping StatsDisconnectAction = { _ in },
        disconnectFileTabs: FileTabsDisconnectAction? = nil
    ) {
        resourceDisconnects = ResourceDisconnects(
            disconnectRemoteFiles: disconnectRemoteFiles,
            disconnectStats: disconnectStats,
            disconnectFileTabs: disconnectFileTabs
        )
    }

    @discardableResult
    func requestServerDisconnect(
        serverId: UUID,
        disconnectRemoteFiles: @escaping RemoteFilesDisconnectAction,
        disconnectStats: @escaping StatsDisconnectAction = { _ in },
        disconnectFileTabs: FileTabsDisconnectAction? = nil,
        disconnectTerminals: @escaping TerminalDisconnectAction,
        onCompleted: @escaping @MainActor () -> Void = {}
    ) -> UUID {
        if let requestID = disconnectRequestByServer[serverId] {
            disconnectRequests[requestID]?.onCompleted.append(onCompleted)
            return requestID
        }

        let requestID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.disconnectRequests.removeValue(forKey: requestID)
                if self.disconnectRequestByServer[serverId] == requestID {
                    self.disconnectRequestByServer.removeValue(forKey: serverId)
                }
            }

            let remoteFilesDisconnectTask = disconnectRemoteFiles(serverId)
            await remoteFilesDisconnectTask.value

            guard !Task.isCancelled else { return }
            await disconnectStats(serverId)
            guard !Task.isCancelled else { return }
            disconnectFileTabs?(serverId)
            await disconnectTerminals(serverId)

            self.deliverCompletionCallbacks(for: requestID)
        }

        disconnectRequests[requestID] = DisconnectRequest(
            serverId: serverId,
            task: task,
            onCompleted: [onCompleted]
        )
        disconnectRequestByServer[serverId] = requestID
        return requestID
    }

    func waitForDisconnectRequest(_ requestID: UUID) async {
        await disconnectRequests[requestID]?.task.value
    }

    func disconnectServerBeforeDeletion(
        server: Server,
        disconnectRemoteFiles: RemoteFilesDisconnectAction? = nil,
        disconnectStats: StatsDisconnectAction? = nil,
        disconnectFileTabs: FileTabsDisconnectAction? = nil,
        disconnectConnectionSessions: @escaping DeletionTerminalDisconnectAction = { serverId in
            await ConnectionSessionManager.shared.disconnectServerAndWait(serverId)
        },
        disconnectTerminalTabs: @escaping DeletionTerminalDisconnectAction = { serverId in
            await TerminalTabManager.shared.disconnectServerAndWait(serverId)
        }
    ) async {
        let resourceDisconnects = self.resourceDisconnects
        let requestID = requestServerDisconnect(
            serverId: server.id,
            disconnectRemoteFiles: disconnectRemoteFiles ?? resourceDisconnects.disconnectRemoteFiles,
            disconnectStats: disconnectStats ?? resourceDisconnects.disconnectStats,
            disconnectFileTabs: disconnectFileTabs ?? resourceDisconnects.disconnectFileTabs,
            disconnectTerminals: { serverId in
                await disconnectConnectionSessions(serverId)
                guard !Task.isCancelled else { return }
                await disconnectTerminalTabs(serverId)
            }
        )
        await waitForDisconnectRequest(requestID)
    }

    private func deliverCompletionCallbacks(for requestID: UUID) {
        var nextCallbackIndex = 0
        while let callbacks = disconnectRequests[requestID]?.onCompleted,
              nextCallbackIndex < callbacks.count {
            let callback = callbacks[nextCallbackIndex]
            nextCallbackIndex += 1
            callback()
        }
    }
}
