import Foundation

@MainActor
final class StoreProductLoadCoordinator {
    typealias StoreProductLoadAction = @MainActor () async -> Void
    typealias StoreProductLoadCompletion = @MainActor () -> Void

    nonisolated private let cancellationBox = StoreTaskCancellationBox()
    private let defaultLoadAction: StoreProductLoadAction?
    private var requestTask: Task<Void, Never>?
    private var requestID: UUID?
    private var completionCallbacks: [StoreProductLoadCompletion] = []

    init(loadAction: StoreProductLoadAction? = nil) {
        defaultLoadAction = loadAction
    }

    var pendingRequestIDs: Set<UUID> {
        guard let requestID else { return [] }
        return [requestID]
    }

    @discardableResult
    func requestLoad(
        onCompleted: @escaping StoreProductLoadCompletion = {},
        operation: StoreProductLoadAction? = nil
    ) -> UUID {
        if let requestID {
            completionCallbacks.append(onCompleted)
            return requestID
        }

        let loadAction = operation ?? defaultLoadAction
        let requestID = UUID()
        self.requestID = requestID
        completionCallbacks = [onCompleted]

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.requestID == requestID {
                    self.clearRequest()
                }
            }

            await loadAction?()
            guard !Task.isCancelled else { return }
            guard self.requestID == requestID else { return }

            let callbacks = self.completionCallbacks
            self.clearRequest()
            callbacks.forEach { $0() }
        }

        if self.requestID == requestID {
            requestTask = task
            cancellationBox.set(task)
        }
        return requestID
    }

    func waitForLoad(_ requestID: UUID) async {
        guard self.requestID == requestID else { return }
        await requestTask?.value
    }

    func cancelRequest(_ requestID: UUID) {
        guard self.requestID == requestID else { return }
        requestTask?.cancel()
    }

    func cancelAll() {
        cancellationBox.cancel()
    }

    nonisolated func cancelAllFromAnyContext() {
        cancellationBox.cancel()
    }

    func cancelAllAndWait() async {
        let task = requestTask
        cancellationBox.cancel()
        await task?.value
        requestTask = nil
        requestID = nil
        completionCallbacks = []
        cancellationBox.clear()
    }

    private func clearRequest() {
        requestID = nil
        requestTask = nil
        completionCallbacks = []
        cancellationBox.clear()
    }
}
