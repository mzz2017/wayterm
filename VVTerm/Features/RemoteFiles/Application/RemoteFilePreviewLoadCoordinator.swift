import Foundation

@MainActor
final class RemoteFilePreviewLoadCoordinator {
    typealias PreviewLoader = @MainActor () async -> Void

    private struct LoadRequest {
        let entryPath: String
        let allowLargeDownloads: Bool
        let task: Task<Void, Never>
    }

    private var requests: [UUID: LoadRequest] = [:]
    private var requestByTab: [UUID: UUID] = [:]

    var pendingRequestIDs: Set<UUID> {
        Set(requestByTab.values)
    }

    @discardableResult
    func requestLoad(
        for entry: RemoteFileEntry,
        in tab: RemoteFileTab,
        server: Server,
        allowLargeDownloads: Bool,
        onCancelPrevious: @escaping @MainActor () -> Void,
        loadPreview: @escaping PreviewLoader
    ) -> UUID? {
        guard tab.serverId == server.id else { return nil }
        guard entry.supportsPreview else { return nil }

        if let existingRequestID = requestByTab[tab.id],
           let existingRequest = requests[existingRequestID] {
            if existingRequest.entryPath == entry.path,
               existingRequest.allowLargeDownloads == allowLargeDownloads {
                return existingRequestID
            }

            _ = cancelRequest(for: tab.id)
            onCancelPrevious()
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

            guard !Task.isCancelled else { return }
            await loadPreview()
        }

        requests[requestID] = LoadRequest(
            entryPath: entry.path,
            allowLargeDownloads: allowLargeDownloads,
            task: task
        )
        requestByTab[tab.id] = requestID
        return requestID
    }

    func waitForRequest(_ requestID: UUID) async {
        await requests[requestID]?.task.value
    }

    func cancelRequest(for tabId: UUID) -> Task<Void, Never>? {
        guard let requestID = requestByTab.removeValue(forKey: tabId),
              let task = requests[requestID]?.task else {
            return nil
        }
        task.cancel()
        return task
    }
}
