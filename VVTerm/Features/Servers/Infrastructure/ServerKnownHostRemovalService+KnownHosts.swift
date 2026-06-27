import Foundation

extension KnownHostsStore: ServerKnownHostRemovingStore {}

extension ServerKnownHostRemovalService {
    static let shared = ServerKnownHostRemovalService(store: KnownHostsStore.shared)
}
