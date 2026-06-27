import Foundation

@MainActor
final class RemoteFileNavigationRequestCoordinator {
    typealias NavigationPerformer = @MainActor (UUID) async -> RemoteFileNavigationResult
    typealias Completion = @MainActor (RemoteFileNavigationResult) -> Void

    private struct NavigationRequest {
        let tabId: UUID
        let serverId: UUID
        let task: Task<Void, Never>
    }

    private var requests: [UUID: NavigationRequest] = [:]
    private var requestByTab: [UUID: UUID] = [:]

    var pendingRequestIDs: Set<UUID> {
        Set(requestByTab.values)
    }

    @discardableResult
    func requestNavigation(
        in tab: RemoteFileTab,
        server: Server,
        onCancelPrevious: @escaping @MainActor (UUID) -> Void,
        perform: @escaping NavigationPerformer,
        onCompleted: @escaping Completion
    ) -> UUID {
        guard tab.serverId == server.id else {
            let requestID = UUID()
            onCompleted(.skipped)
            return requestID
        }

        if cancelRequest(for: tab.id) {
            onCancelPrevious(tab.id)
        }

        let requestID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                requests.removeValue(forKey: requestID)
                if requestByTab[tab.id] == requestID {
                    requestByTab.removeValue(forKey: tab.id)
                }
            }

            guard isCurrentRequest(requestID, for: tab.id) else { return }
            let result = await perform(requestID)
            guard isCurrentRequest(requestID, for: tab.id) else { return }
            onCompleted(result)
        }

        requests[requestID] = NavigationRequest(tabId: tab.id, serverId: server.id, task: task)
        requestByTab[tab.id] = requestID
        return requestID
    }

    func waitForRequest(_ requestID: UUID) async {
        await requests[requestID]?.task.value
    }

    @discardableResult
    func cancelRequest(for tabId: UUID) -> Bool {
        guard let requestID = requestByTab.removeValue(forKey: tabId) else { return false }
        requests[requestID]?.task.cancel()
        return true
    }

    func affectedTabIDs(for serverId: UUID) -> Set<UUID> {
        Set(
            requests.values.compactMap { request in
                request.serverId == serverId ? request.tabId : nil
            }
        )
    }

    func isCurrentRequest(_ requestID: UUID, for tabId: UUID) -> Bool {
        !Task.isCancelled && requestByTab[tabId] == requestID
    }
}
