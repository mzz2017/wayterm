import Foundation
import Combine
import os.log

// MARK: - Server Stats Collector

/// Main stats collector that uses a shared SSH connection when available
@MainActor
final class ServerStatsCollector: ObservableObject {
    struct StatsConnection {
        let client: SSHClient?
        let lease: RemoteConnectionLease

        init(client: SSHClient? = nil, lease: RemoteConnectionLease) {
            self.client = client
            self.lease = lease
        }
    }

    typealias ConnectionFactory = @MainActor (Server, SSHClient?) -> StatsConnection
    typealias CredentialsProvider = @MainActor (Server) throws -> ServerCredentials
    typealias CollectionTaskFactory = @MainActor (
        ServerStatsCollector,
        Server,
        ServerCredentials,
        StatsConnection
    ) -> Task<Void, Never>

    @Published var stats = ServerStats()
    @Published var cpuHistory: [StatsPoint] = []
    @Published var memoryHistory: [StatsPoint] = []
    @Published var isCollecting = false
    @Published var connectionError: String?

    private var collectTask: Task<Void, Never>?
    private var pendingStopTask: Task<Void, Never>?
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VVTerm", category: "Stats")
    private let connectionFactory: ConnectionFactory
    private let credentialsProvider: CredentialsProvider
    private let collectionTaskFactory: CollectionTaskFactory

    private var connectionLease: RemoteConnectionLease?

    // Platform detection and collector
    private var remotePlatform: RemotePlatform = .unknown
    private var platformCollector: PlatformStatsCollector?
    private let context = StatsCollectionContext()

    init(
        connectionFactory: @escaping ConnectionFactory = ServerStatsCollector.makeConnection,
        credentialsProvider: @escaping CredentialsProvider = { server in
            try KeychainManager.shared.getCredentials(for: server)
        },
        collectionTaskFactory: @escaping CollectionTaskFactory = ServerStatsCollector.makeCollectionTask
    ) {
        self.connectionFactory = connectionFactory
        self.credentialsProvider = credentialsProvider
        self.collectionTaskFactory = collectionTaskFactory
    }

    // MARK: - Collection Control

    func startCollecting(for server: Server, using sharedClient: SSHClient? = nil) async {
        if let pendingStopTask {
            await pendingStopTask.value
            self.pendingStopTask = nil
        }

        if let collectTask, !isCollecting {
            await collectTask.value
            self.collectTask = nil
        }

        guard !isCollecting else { return }
        isCollecting = true
        connectionError = nil
        resetCollectionState()

        let connection = connectionFactory(server, sharedClient)
        configureConnectionState(lease: connection.lease)

        // Get credentials
        let credentials: ServerCredentials
        do {
            credentials = try credentialsProvider(server)
        } catch {
            await connection.lease.close()
            finishCollection(withError: "No credentials found")
            return
        }

        collectTask = collectionTaskFactory(self, server, credentials, connection)
    }

    @discardableResult
    func stopCollecting() -> Task<Void, Never>? {
        if let pendingStopTask {
            return pendingStopTask
        }

        guard isCollecting || collectTask != nil || connectionLease != nil else {
            return nil
        }

        isCollecting = false
        collectTask?.cancel()

        let stopTask = Task { @MainActor in
            await self.finishStoppingCollection()
        }
        pendingStopTask = stopTask
        return stopTask
    }

    func stopCollectingAndWait() async {
        guard let stopTask = stopCollecting() else { return }
        await stopTask.value
    }

    // MARK: - Stats Collection

    private func collectStats(client: SSHClient) async throws {
        // Detect platform and create collector on first run
        if remotePlatform == .unknown {
            remotePlatform = await client.remotePlatform()
            platformCollector = remotePlatform.createCollector()

            logger.info("Detected remote platform: \(self.remotePlatform.rawValue)")

            // Get initial system info
            let systemInfo = try await platformCollector?.getSystemInfo(client: client)
            await MainActor.run {
                self.applySystemInfo(systemInfo)
            }
        }

        // Collect stats using platform-specific collector
        guard let collector = platformCollector else { return }

        var newStats = try await collector.collectStats(client: client, context: context)

        // Preserve system info
        let existingStats = await MainActor.run { self.stats }
        newStats.hostname = existingStats.hostname
        newStats.osInfo = existingStats.osInfo
        newStats.cpuCores = existingStats.cpuCores

        // Update on main thread
        await MainActor.run {
            self.applyCollectedStats(newStats)
        }
    }

    private func resetCollectionState() {
        context.reset()
        remotePlatform = .unknown
        platformCollector = nil
    }

    private func configureConnectionState(lease: RemoteConnectionLease) {
        connectionLease = lease
    }

    private func clearConnectionState() {
        connectionLease = nil
    }

    private func finishCollection(withError error: String? = nil) {
        connectionError = error
        isCollecting = false
        clearConnectionState()
    }

    func recordCollectionFinished() {
        finishCollection()
    }

    func recordCollectionFailure(_ error: Error) {
        guard !(error is CancellationError) else { return }
        finishCollection(withError: error.localizedDescription)
    }

    func beginCollectionTeardown() {
        isCollecting = false
    }

    private func finishStoppingCollection() async {
        let task = collectTask
        let lease = connectionLease
        collectTask = nil
        clearConnectionState()

        task?.cancel()
        await task?.value
        await lease?.close()
        finishCollection()
        pendingStopTask = nil
    }

    private func applySystemInfo(_ systemInfo: (hostname: String, osInfo: String, cpuCores: Int)?) {
        stats.hostname = systemInfo?.hostname ?? ""
        stats.osInfo = systemInfo?.osInfo ?? ""
        stats.cpuCores = systemInfo?.cpuCores ?? 1
    }

    private func applyCollectedStats(_ newStats: ServerStats) {
        stats = newStats

        cpuHistory.append(StatsPoint(timestamp: newStats.timestamp, value: newStats.cpuUsage))
        memoryHistory.append(StatsPoint(timestamp: newStats.timestamp, value: Double(newStats.memoryUsed)))

        if cpuHistory.count > 60 { cpuHistory.removeFirst() }
        if memoryHistory.count > 60 { memoryHistory.removeFirst() }
    }

    private static func makeConnection(server _: Server, sharedClient: SSHClient?) -> StatsConnection {
        if let sharedClient {
            return StatsConnection(
                client: sharedClient,
                lease: RemoteConnectionLease(client: sharedClient, ownership: .borrowed)
            )
        }

        let client = SSHClient()
        return StatsConnection(
            client: client,
            lease: RemoteConnectionLease(client: client, ownership: .owned)
        )
    }

    private static func makeCollectionTask(
        collector: ServerStatsCollector,
        server: Server,
        credentials: ServerCredentials,
        connection: StatsConnection
    ) -> Task<Void, Never> {
        Task.detached(priority: .utility) { [weak collector] in
            guard let collector, let client = connection.client else {
                await connection.lease.close()
                return
            }
            var collectionError: Error?

            do {
                try await SSHConnectionOperationService.shared.runWithConnection(
                    using: client,
                    server: server,
                    credentials: credentials,
                    disconnectWhenDone: false
                ) { connectedClient in
                    await MainActor.run {
                        collector.connectionError = nil
                    }

                    while !Task.isCancelled {
                        let shouldContinue = await MainActor.run { collector.isCollecting }
                        guard shouldContinue else { break }

                        try await collector.collectStats(client: connectedClient)
                        try? await Task.sleep(for: .seconds(2))
                    }
                }
            } catch {
                if error is CancellationError {
                    // User-driven stop is normal lifecycle, not a connection error.
                } else {
                    collector.logger.error("Failed to collect stats: \(error.localizedDescription)")
                    collectionError = error
                    await MainActor.run {
                        collector.beginCollectionTeardown()
                    }
                }
            }

            await connection.lease.close()
            await MainActor.run {
                collector.collectTask = nil
                if let collectionError {
                    collector.recordCollectionFailure(collectionError)
                } else {
                    collector.recordCollectionFinished()
                }
            }
        }
    }
}
