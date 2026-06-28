import Foundation
import Combine

@MainActor
final class ServerStatsCollectionRegistry: ObservableObject {
    typealias CollectorFactory = @MainActor () -> ServerStatsCollector

    private var collectorsByServer: [UUID: ServerStatsCollector] = [:]
    private let collectorFactory: CollectorFactory

    init(
        collectorFactory: @escaping CollectorFactory = {
            ServerStatsCollector(connectionProvider: StatsSSHConnectionProvider.makeProvider())
        }
    ) {
        self.collectorFactory = collectorFactory
    }

    func collector(for serverId: UUID) -> ServerStatsCollector {
        if let collector = collectorsByServer[serverId] {
            return collector
        }

        let collector = collectorFactory()
        collectorsByServer[serverId] = collector
        return collector
    }

    func disconnect(serverId: UUID) async {
        guard let collector = collectorsByServer[serverId] else { return }
        await collector.stopCollectingAndWait()
        if collectorsByServer[serverId] === collector {
            collectorsByServer.removeValue(forKey: serverId)
        }
    }
}
