import Foundation

@MainActor
final class RemoteFileMoveDestinationLoadCoordinator {
    typealias DirectoryLoader = @MainActor (String, Server) async throws -> [RemoteFileEntry]
    typealias Completion = @MainActor (Result<[RemoteFileEntry], Error>) -> Void

    private struct LoadRequest {
        let key: LoadRequestKey
        var task: Task<Void, Never>?
        var onCompleted: [Completion]
    }

    private struct LoadRequestKey: Hashable {
        let serverId: UUID
        let path: String
    }

    private var requests: [UUID: LoadRequest] = [:]
    private var requestByKey: [LoadRequestKey: UUID] = [:]

    var pendingRequestIDs: Set<UUID> {
        Set(requestByKey.values)
    }

    @discardableResult
    func requestLoad(
        path: String,
        server: Server,
        loadDirectories: @escaping DirectoryLoader,
        onCompleted: @escaping Completion
    ) -> UUID {
        let normalizedPath = RemoteFilePath.normalize(path)
        let key = LoadRequestKey(serverId: server.id, path: normalizedPath)

        if let requestID = requestByKey[key] {
            requests[requestID]?.onCompleted.append(onCompleted)
            return requestID
        }

        let requestID = UUID()
        requests[requestID] = LoadRequest(
            key: key,
            task: nil,
            onCompleted: [onCompleted]
        )
        requestByKey[key] = requestID

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                requests.removeValue(forKey: requestID)
                if requestByKey[key] == requestID {
                    requestByKey.removeValue(forKey: key)
                }
            }

            let result: Result<[RemoteFileEntry], Error>
            do {
                let entries = try await loadDirectories(normalizedPath, server)
                result = .success(entries)
            } catch {
                result = .failure(error)
            }

            guard !Task.isCancelled else { return }
            guard requestByKey[key] == requestID else { return }

            let callbacks = requests[requestID]?.onCompleted ?? []
            callbacks.forEach { $0(result) }
        }

        if requests[requestID]?.key == key {
            requests[requestID]?.task = task
        }

        return requestID
    }

    func waitForRequest(_ requestID: UUID) async {
        await requests[requestID]?.task?.value
    }

    @discardableResult
    func cancelRequests(for serverId: UUID) -> [Task<Void, Never>] {
        var canceledTasks: [Task<Void, Never>] = []
        for (requestID, request) in requests where request.key.serverId == serverId {
            if let canceledTask = cancelRequest(requestID) {
                canceledTasks.append(canceledTask)
            }
        }
        return canceledTasks
    }

    @discardableResult
    func cancelRequest(_ requestID: UUID) -> Task<Void, Never>? {
        guard let request = requests[requestID] else { return nil }
        if requestByKey[request.key] == requestID {
            requestByKey.removeValue(forKey: request.key)
        }
        requests[requestID]?.task?.cancel()
        return requests[requestID]?.task
    }
}
