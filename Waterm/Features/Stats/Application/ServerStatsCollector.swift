import Foundation
import Combine
import os.log

// MARK: - Server Stats Collector

@MainActor
struct StatsConnectionProvider {
    typealias OwnedConnectionFactory = @MainActor (Server, ServerCredentials) -> ServerStatsCollector.StatsConnection

    private let ownedConnectionFactory: OwnedConnectionFactory

    init(ownedConnectionFactory: @escaping OwnedConnectionFactory) {
        self.ownedConnectionFactory = ownedConnectionFactory
    }

    func connection(
        for server: Server,
        credentials: ServerCredentials,
        borrowedLease: RemoteConnectionLease?
    ) -> ServerStatsCollector.StatsConnection {
        if let borrowedLease {
            return ServerStatsCollector.StatsConnection(lease: borrowedLease)
        }

        return ownedConnectionFactory(server, credentials)
    }
}

/// Main stats collector that uses a borrowed remote connection lease when available.
@MainActor
final class ServerStatsCollector: ObservableObject {
    private struct StatsCollectionRequest {
        let task: Task<Void, Never>
    }

    struct StatsConnection {
        typealias ExecutorOperation = @Sendable (any RemoteCommandExecuting) async throws -> Void
        typealias ExecutorRunner = @Sendable (
            RemoteConnectionLease,
            Server,
            ServerCredentials,
            @escaping ExecutorOperation
        ) async throws -> Void

        let lease: RemoteConnectionLease
        private let executorRunner: ExecutorRunner

        init(
            lease: RemoteConnectionLease,
            executorRunner: @escaping ExecutorRunner = StatsConnection.runWithLeasedExecutor
        ) {
            self.lease = lease
            self.executorRunner = executorRunner
        }

        func run(
            server: Server,
            credentials: ServerCredentials,
            operation: @escaping ExecutorOperation
        ) async throws {
            try await executorRunner(lease, server, credentials, operation)
        }

        private static func runWithLeasedExecutor(
            lease: RemoteConnectionLease,
            server _: Server,
            credentials _: ServerCredentials,
            operation: @escaping ExecutorOperation
        ) async throws {
            try await lease.withExclusiveClient { leasedClient in
                try await operation(leasedClient)
            }
        }
    }

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
    private var statsCollectionRequests: [UUID: StatsCollectionRequest] = [:]
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Waterm", category: "Stats")
    private let connectionProvider: StatsConnectionProvider
    private let credentialsProvider: CredentialsProvider
    private let collectionTaskFactory: CollectionTaskFactory

    private var connectionLease: RemoteConnectionLease?

    // Platform detection and collector
    private var remotePlatform: RemotePlatform = .unknown
    private var platformCollector: PlatformStatsCollector?
    private let context = StatsCollectionContext()

    init(
        connectionProvider: StatsConnectionProvider,
        credentialsProvider: @escaping CredentialsProvider = { server in
            try KeychainManager.shared.getCredentials(for: server)
        },
        collectionTaskFactory: @escaping CollectionTaskFactory = ServerStatsCollector.makeCollectionTask
    ) {
        self.connectionProvider = connectionProvider
        self.credentialsProvider = credentialsProvider
        self.collectionTaskFactory = collectionTaskFactory
    }

    // MARK: - Collection Control

    var pendingStatsCollectionRequestIDs: Set<UUID> {
        Set(statsCollectionRequests.keys)
    }

    @discardableResult
    func requestStartCollecting(for server: Server, using borrowedLease: RemoteConnectionLease? = nil) -> UUID? {
        cancelStatsCollectionRequests()

        let requestID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.statsCollectionRequests.removeValue(forKey: requestID) }

            guard !Task.isCancelled else { return }
            await self.startCollecting(for: server, using: borrowedLease)
        }

        statsCollectionRequests[requestID] = StatsCollectionRequest(task: task)
        return requestID
    }

    @discardableResult
    func requestStopCollecting() -> UUID? {
        let canceledRequestTasks = cancelStatsCollectionRequests()
        guard isCollecting || collectTask != nil || connectionLease != nil || pendingStopTask != nil || !canceledRequestTasks.isEmpty else {
            return nil
        }

        let requestID = UUID()
        let task = Task { @MainActor [weak self] in
            for task in canceledRequestTasks {
                await task.value
            }

            guard let self else { return }
            defer { self.statsCollectionRequests.removeValue(forKey: requestID) }

            await self.stopCollectingAndWait()
        }

        statsCollectionRequests[requestID] = StatsCollectionRequest(task: task)
        return requestID
    }

    func waitForStatsCollectionRequest(_ requestID: UUID) async {
        await statsCollectionRequests[requestID]?.task.value
    }

    func startCollecting(for server: Server, using borrowedLease: RemoteConnectionLease? = nil) async {
        if let pendingStopTask {
            await pendingStopTask.value
            self.pendingStopTask = nil
            guard !Task.isCancelled else { return }
        }

        if let collectTask, !isCollecting {
            await collectTask.value
            self.collectTask = nil
            guard !Task.isCancelled else { return }
        }

        if shouldReplaceActiveCollection(using: borrowedLease) {
            await stopCollectingAndWait()
            guard !Task.isCancelled else { return }
        }

        guard !Task.isCancelled else { return }
        guard !isCollecting else { return }
        isCollecting = true
        connectionError = nil
        resetCollectionState()

        // Get credentials
        let credentials: ServerCredentials
        do {
            credentials = try credentialsProvider(server)
        } catch {
            finishCollection(withError: "No credentials found")
            return
        }

        let connection = connectionProvider.connection(
            for: server,
            credentials: credentials,
            borrowedLease: borrowedLease
        )
        configureConnectionState(lease: connection.lease)

        collectTask = collectionTaskFactory(self, server, credentials, connection)
    }

    private func shouldReplaceActiveCollection(using borrowedLease: RemoteConnectionLease?) -> Bool {
        guard isCollecting, let connectionLease else { return false }

        switch (connectionLease.ownership, borrowedLease) {
        case (.borrowed, .some(let borrowedLease)):
            return !connectionLease.sharesClient(with: borrowedLease)
        case (.borrowed, .none):
            return true
        case (.owned, .some):
            return true
        case (.owned, .none):
            return false
        }
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

    @discardableResult
    private func cancelStatsCollectionRequests() -> [Task<Void, Never>] {
        let requests = statsCollectionRequests.values.map(\.task)
        requests.forEach { $0.cancel() }
        return requests
    }

    // MARK: - Stats Collection

    private func collectStats(executor: any RemoteCommandExecuting) async throws {
        // Detect platform and create collector on first run
        if remotePlatform == .unknown {
            remotePlatform = await executor.remoteEnvironment().platform
            platformCollector = remotePlatform.createCollector()

            logger.info("Detected remote platform: \(self.remotePlatform.rawValue)")

            // Get initial system info
            let systemInfo = try await platformCollector?.getSystemInfo(executor: executor)
            await MainActor.run {
                self.applySystemInfo(systemInfo)
            }
        }

        // Collect stats using platform-specific collector
        guard let collector = platformCollector else { return }

        var newStats = try await collector.collectStats(executor: executor, context: context)

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

    private static func makeCollectionTask(
        collector: ServerStatsCollector,
        server: Server,
        credentials: ServerCredentials,
        connection: StatsConnection
    ) -> Task<Void, Never> {
        Task.detached(priority: .utility) { [weak collector] in
            guard let collector else {
                await connection.lease.close()
                return
            }
            let collectionFailure: Error?

            do {
                try await connection.run(
                    server: server,
                    credentials: credentials
                ) { executor in
                    try await collector.collectStatsUntilStopped(executor: executor)
                }
                collectionFailure = nil
            } catch {
                if error is CancellationError {
                    // User-driven stop is normal lifecycle, not a connection error.
                    collectionFailure = nil
                } else {
                    collector.logger.error("Failed to collect stats: \(error.localizedDescription)")
                    collectionFailure = error
                    await MainActor.run {
                        collector.beginCollectionTeardown()
                    }
                }
            }

            await connection.lease.close()
            await MainActor.run {
                collector.collectTask = nil
                if let collectionFailure {
                    collector.recordCollectionFailure(collectionFailure)
                } else {
                    collector.recordCollectionFinished()
                }
            }
        }
    }

    private func collectStatsUntilStopped(executor: any RemoteCommandExecuting) async throws {
        connectionError = nil

        while !Task.isCancelled {
            guard isCollecting else { break }

            try await collectStats(executor: executor)
            try? await Task.sleep(for: .seconds(2))
        }
    }
}
