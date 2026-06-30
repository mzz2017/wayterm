import Foundation

nonisolated struct ServerStatsCollectionTaskKey: Equatable {
    let serverId: UUID
    let isVisible: Bool
    private let borrowedClientIdentity: ObjectIdentifier?

    init(
        serverId: UUID,
        isVisible: Bool,
        borrowedLease: RemoteConnectionLease?
    ) {
        self.serverId = serverId
        self.isVisible = isVisible
        self.borrowedClientIdentity = isVisible
            ? borrowedLease.map { ObjectIdentifier($0.client) }
            : nil
    }
}
