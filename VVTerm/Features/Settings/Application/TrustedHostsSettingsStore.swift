import Combine
import Foundation

protocol KnownHostsStoring: Sendable {
    func entries() async -> [KnownHostsManager.Entry]
    func removeAll() async
}

extension KnownHostsStore: KnownHostsStoring {}

@MainActor
final class TrustedHostsSettingsStore: ObservableObject {
    static let shared = TrustedHostsSettingsStore()

    @Published private(set) var knownHostCount = 0

    private let knownHostsStore: any KnownHostsStoring
    private var knownHostsTasks: [UUID: Task<Void, Never>] = [:]
    private var latestKnownHostsRequestID: UUID?

    var pendingKnownHostsTaskIDs: Set<UUID> {
        Set(knownHostsTasks.keys)
    }

    init(knownHostsStore: any KnownHostsStoring = KnownHostsStore.shared) {
        self.knownHostsStore = knownHostsStore
    }

    @discardableResult
    func refreshKnownHostCount() -> UUID {
        trackKnownHostsTask { [knownHostsStore] in
            await knownHostsStore.entries().count
        }
    }

    @discardableResult
    func resetTrustedHosts() -> UUID {
        trackKnownHostsTask { [knownHostsStore] in
            await knownHostsStore.removeAll()
            return await knownHostsStore.entries().count
        }
    }

    func waitForKnownHostsTask(_ requestID: UUID) async {
        await knownHostsTasks[requestID]?.value
    }

    private func trackKnownHostsTask(_ operation: @escaping @Sendable () async -> Int) -> UUID {
        let requestID = UUID()
        latestKnownHostsRequestID = requestID
        let task = Task { [weak self] in
            defer {
                self?.knownHostsTasks.removeValue(forKey: requestID)
            }
            let count = await operation()
            guard !Task.isCancelled, self?.latestKnownHostsRequestID == requestID else { return }
            self?.knownHostCount = count
        }

        knownHostsTasks[requestID] = task
        return requestID
    }
}
