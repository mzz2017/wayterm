import Foundation

protocol ServerKnownHostRemovingStore: AnyObject, Sendable {
    func remove(host: String, port: Int) async
}

final class ServerKnownHostRemovalService: @unchecked Sendable {
    private let store: any ServerKnownHostRemovingStore

    init(store: any ServerKnownHostRemovingStore) {
        self.store = store
    }

    func removeKnownHosts(for candidates: [ServerKnownHostRemovalCandidate]) async {
        for candidate in candidates {
            await store.remove(host: candidate.host, port: candidate.port)
        }
    }
}
