import Foundation
import Testing
@testable import VVTerm

// Test Context:
// These tests protect Stats collection lifecycle ordering. Stats may borrow a
// terminal-owned SSH connection or create an owned fallback connection, but stop
// must await accepted lease teardown before a restart can replace the runtime.
// Fakes are actor based and perform no network, keychain, or filesystem I/O.
// Update these tests only if Stats intentionally changes its connection
// ownership or stop/restart ordering contract.
@MainActor
struct ServerStatsCollectorLifecycleTests {
    @Test
    func collectorUsesInjectedStatsConnectionProviderForOwnedFallback() async throws {
        let server = makeServer()
        let client = RecordingStatsLeaseClient()
        var ownedFactoryCallCount = 0
        let provider = StatsConnectionProvider(
            ownedConnectionFactory: { server, credentials in
                ownedFactoryCallCount += 1
                #expect(credentials.serverId == server.id)
                return .init(lease: RemoteConnectionLease(client: client, ownership: .owned))
            }
        )
        let collector = ServerStatsCollector(
            connectionProvider: provider,
            credentialsProvider: { server in
                makeCredentials(serverId: server.id)
            },
            collectionTaskFactory: { _, _, _, _ in
                Task {}
            }
        )

        await collector.startCollecting(for: server)

        #expect(
            ownedFactoryCallCount == 1,
            "Stats owned fallback must be created through the injected provider boundary."
        )
        await collector.stopCollectingAndWait()
    }

    @Test
    func stopCollectingAndWaitAwaitsOwnedLeaseDisconnect() async throws {
        let server = makeServer()
        let client = BlockingStatsLeaseClient()
        let collector = makeCollector(
            ownedConnectionFactory: OneShotStatsOwnedConnectionFactory([
                .init(lease: RemoteConnectionLease(client: client, ownership: .owned))
            ])
        )
        let stopCompletion = AsyncFlag()

        await collector.startCollecting(for: server)

        let stopTask = Task {
            await collector.stopCollectingAndWait()
            await stopCompletion.mark()
        }

        await client.waitUntilDisconnectStarted()
        try await Task.sleep(for: .milliseconds(20))
        let completedBeforeRelease = await stopCompletion.isMarked()
        #expect(!completedBeforeRelease, "stopCollectingAndWait must not finish while owned lease disconnect is still running")

        await client.releaseDisconnect()
        await stopTask.value

        let disconnects = await client.disconnectCount()
        #expect(disconnects == 1, "Owned Stats lease should disconnect exactly once during awaited stop")
    }

    @Test
    func startCollectingWaitsForPendingStopBeforeReplacingOwnedLease() async throws {
        let server = makeServer()
        let firstClient = BlockingStatsLeaseClient()
        let secondClient = RecordingStatsLeaseClient()
        let factory = OneShotStatsOwnedConnectionFactory([
            .init(lease: RemoteConnectionLease(client: firstClient, ownership: .owned)),
            .init(lease: RemoteConnectionLease(client: secondClient, ownership: .owned))
        ])
        let collector = makeCollector(ownedConnectionFactory: factory)

        await collector.startCollecting(for: server)
        let stopTask = collector.stopCollecting()
        await firstClient.waitUntilDisconnectStarted()

        let restartTask = Task {
            await collector.startCollecting(for: server)
        }

        try await Task.sleep(for: .milliseconds(20))
        let callsBeforeRelease = factory.callCount
        #expect(callsBeforeRelease == 1, "Restart must wait for pending stop before creating a replacement Stats lease")

        await firstClient.releaseDisconnect()
        await stopTask?.value
        await restartTask.value

        let callsAfterRelease = factory.callCount
        #expect(callsAfterRelease == 2, "Restart should create the replacement lease after pending stop completes")
        let secondDisconnects = await secondClient.disconnectCount()
        #expect(secondDisconnects == 0, "Restart should leave the replacement lease active")
    }

    @Test
    func startRequestRemainsPendingUntilQueuedRestartExits() async throws {
        let server = makeServer()
        let firstClient = BlockingStatsLeaseClient()
        let secondClient = RecordingStatsLeaseClient()
        let factory = OneShotStatsOwnedConnectionFactory([
            .init(lease: RemoteConnectionLease(client: firstClient, ownership: .owned)),
            .init(lease: RemoteConnectionLease(client: secondClient, ownership: .owned))
        ])
        let collector = makeCollector(ownedConnectionFactory: factory)

        // Given an active Stats collection whose stop is still closing the
        // owned lease.
        await collector.startCollecting(for: server)
        let stopTask = collector.stopCollecting()
        await firstClient.waitUntilDisconnectStarted()

        // When a new visible/retry start intent arrives while stop is pending.
        let requestID = try #require(collector.requestStartCollecting(for: server))

        // Then the request remains visible and does not create the replacement
        // lease until the pending stop has completed.
        try await Task.sleep(for: .milliseconds(20))
        #expect(
            collector.pendingStatsCollectionRequestIDs.contains(requestID),
            "Queued Stats start request must stay pending while it waits for the prior stop to finish."
        )
        #expect(
            factory.callCount == 1,
            "Queued Stats start request must not create a replacement lease before pending stop completes."
        )

        await firstClient.releaseDisconnect()
        await stopTask?.value
        await collector.waitForStatsCollectionRequest(requestID)

        #expect(
            !collector.pendingStatsCollectionRequestIDs.contains(requestID),
            "Stats start request should clear only after its tracked task exits."
        )
        #expect(
            factory.callCount == 2,
            "Stats start request should create the replacement lease after pending stop completes."
        )
    }

    @Test
    func stopRequestCancelsQueuedStartBeforeReplacementLeaseIsCreated() async throws {
        let server = makeServer()
        let firstClient = BlockingStatsLeaseClient()
        let secondClient = RecordingStatsLeaseClient()
        let factory = OneShotStatsOwnedConnectionFactory([
            .init(lease: RemoteConnectionLease(client: firstClient, ownership: .owned)),
            .init(lease: RemoteConnectionLease(client: secondClient, ownership: .owned))
        ])
        let collector = makeCollector(ownedConnectionFactory: factory)

        // Given a queued start request waiting behind a still-running stop.
        await collector.startCollecting(for: server)
        let originalStopTask = collector.stopCollecting()
        await firstClient.waitUntilDisconnectStarted()
        let startRequestID = try #require(collector.requestStartCollecting(for: server))
        try await Task.sleep(for: .milliseconds(20))
        #expect(
            factory.callCount == 1,
            "Queued Stats start should not create a replacement lease while the old lease is still closing."
        )

        // When a newer hidden/disappear stop intent wins over the queued start.
        let stopRequestID = try #require(collector.requestStopCollecting())
        await firstClient.releaseDisconnect()
        await originalStopTask?.value
        await collector.waitForStatsCollectionRequest(startRequestID)
        await collector.waitForStatsCollectionRequest(stopRequestID)

        // Then the canceled start remains awaitable until exit, does not publish
        // an error, and never creates the replacement lease.
        #expect(
            factory.callCount == 1,
            "Canceled queued Stats start must not create a replacement lease after a newer stop intent wins."
        )
        #expect(
            collector.connectionError == nil,
            "Stats request cancellation is lifecycle intent and must not publish a user-facing connection error."
        )
        #expect(
            !collector.pendingStatsCollectionRequestIDs.contains(startRequestID),
            "Canceled queued Stats start request should clear after its tracked task exits."
        )
        #expect(
            !collector.pendingStatsCollectionRequestIDs.contains(stopRequestID),
            "Stats stop request should clear after its tracked task exits."
        )
    }

    @Test
    func stopCollectingDoesNotDisconnectBorrowedSharedClient() async throws {
        let server = makeServer()
        let client = RecordingStatsLeaseClient()
        let collector = makeCollector(
            ownedConnectionFactory: OneShotStatsOwnedConnectionFactory([
                .init(lease: RemoteConnectionLease(client: client, ownership: .borrowed))
            ])
        )

        await collector.startCollecting(for: server)
        await collector.stopCollectingAndWait()

        let disconnects = await client.disconnectCount()
        #expect(disconnects == 0, "Borrowed Stats leases must leave terminal-owned clients connected")
    }

    @Test
    func startCollectingWaitsForFailedCollectionLeaseCloseBeforeRetry() async throws {
        let server = makeServer()
        let failedClient = BlockingStatsLeaseClient()
        let retryClient = RecordingStatsLeaseClient()
        let factory = OneShotStatsOwnedConnectionFactory([
            .init(lease: RemoteConnectionLease(client: failedClient, ownership: .owned)),
            .init(lease: RemoteConnectionLease(client: retryClient, ownership: .owned))
        ])
        let collector = makeCollector(
            ownedConnectionFactory: factory,
            collectionTaskFactory: { collector, _, _, connection in
                Task {
                    collector.beginCollectionTeardown()
                    await connection.lease.close()
                    await MainActor.run {
                        collector.recordCollectionFailure(StatsCollectorLifecycleTestError.expectedFailure)
                    }
                }
            }
        )

        await collector.startCollecting(for: server)
        await failedClient.waitUntilDisconnectStarted()

        let retryTask = Task {
            await collector.startCollecting(for: server)
        }

        try await Task.sleep(for: .milliseconds(20))
        let callsBeforeRelease = factory.callCount
        #expect(callsBeforeRelease == 1, "Retry after Stats failure must wait for failed lease close to finish")

        await failedClient.releaseDisconnect()
        await retryTask.value

        let callsAfterRelease = factory.callCount
        #expect(callsAfterRelease == 2, "Retry should create a replacement lease after failed close finishes")
    }

    @Test
    func cancelledCollectionDoesNotPublishConnectionError() async throws {
        let server = makeServer()
        let client = RecordingStatsLeaseClient()
        let collector = makeCollector(
            ownedConnectionFactory: OneShotStatsOwnedConnectionFactory([
                .init(lease: RemoteConnectionLease(client: client, ownership: .owned))
            ]),
            collectionTaskFactory: { collector, _, _, connection in
                Task {
                    collector.recordCollectionFailure(CancellationError())
                    await connection.lease.close()
                    await MainActor.run {
                        collector.recordCollectionFinished()
                    }
                }
            }
        )

        await collector.startCollecting(for: server)
        try await Task.sleep(for: .milliseconds(20))

        #expect(collector.connectionError == nil, "Cancellation is normal Stats lifecycle and must not publish a connection error")
    }

    @Test
    func collectorUsesCommandExecutorWithoutRawSSHClientOwnership() async throws {
        let server = makeServer()
        let client = ScriptedStatsLeaseClient()
        let collector = ServerStatsCollector(
            connectionProvider: StatsConnectionProvider { server, credentials in
                Issue.record("Unexpected owned Stats connection for \(server.name) with \(credentials.serverId)")
                return .init(lease: RemoteConnectionLease(client: RecordingStatsLeaseClient(), ownership: .owned))
            },
            credentialsProvider: { server in
                makeCredentials(serverId: server.id)
            }
        )

        await collector.startCollecting(
            for: server,
            using: RemoteConnectionLease(client: client, ownership: .borrowed)
        )
        var didCollect = false
        for _ in 0..<25 {
            if await client.commandCount() >= 3 {
                didCollect = true
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        await collector.stopCollectingAndWait()

        #expect(didCollect, "Stats collection should execute commands through the lease command executor even when it is not an SSHClient")
        #expect(collector.stats.hostname == "executor-host", "Stats collector should populate system info from the executor-backed platform collector")
    }

    private func makeCollector(
        ownedConnectionFactory: OneShotStatsOwnedConnectionFactory,
        collectionTaskFactory: ServerStatsCollector.CollectionTaskFactory? = nil
    ) -> ServerStatsCollector {
        ServerStatsCollector(
            connectionProvider: StatsConnectionProvider { server, credentials in
                ownedConnectionFactory.nextConnection(server: server, credentials: credentials)
            },
            credentialsProvider: { server in
                makeCredentials(serverId: server.id)
            },
            collectionTaskFactory: collectionTaskFactory ?? { _, _, _, _ in
                Task {
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(10))
                    }
                }
            }
        )
    }

    private func makeServer() -> Server {
        Server(
            workspaceId: UUID(),
            name: "Stats",
            host: "example.com",
            username: "root"
        )
    }

    private func makeCredentials(serverId: UUID) -> ServerCredentials {
        ServerCredentials(
            serverId: serverId,
            password: nil,
            privateKey: nil,
            publicKey: nil,
            passphrase: nil,
            cloudflareClientID: nil,
            cloudflareClientSecret: nil
        )
    }
}

private enum StatsCollectorLifecycleTestError: Error {
    case expectedFailure
}

@MainActor
private final class OneShotStatsOwnedConnectionFactory {
    private var connections: [ServerStatsCollector.StatsConnection]
    private(set) var callCount = 0

    init(_ connections: [ServerStatsCollector.StatsConnection]) {
        self.connections = connections
    }

    func nextConnection(
        server: Server,
        credentials: ServerCredentials
    ) -> ServerStatsCollector.StatsConnection {
        callCount += 1
        #expect(credentials.serverId == server.id)
        guard !connections.isEmpty else {
            Issue.record("Unexpected Stats connection factory call for \(server.name)")
            return .init(lease: RemoteConnectionLease(client: RecordingStatsLeaseClient(), ownership: .owned))
        }

        return connections.removeFirst()
    }
}

private actor RecordingStatsLeaseClient: RemoteConnectionLeaseClient {
    private var disconnects = 0

    func disconnect() async {
        disconnects += 1
    }

    func disconnectCount() -> Int {
        disconnects
    }

    func execute(_ command: String, timeout: Duration?) async throws -> String {
        ""
    }

    func upload(
        _ data: Data,
        to remotePath: String,
        permissions: Int32,
        strategy: SSHUploadStrategy
    ) async throws {}

    func remoteEnvironment(forceRefresh: Bool) async -> RemoteEnvironment {
        .fallbackPOSIX
    }

    func remoteTerminalType(forceRefresh: Bool) async -> RemoteTerminalType {
        .xterm256Color
    }
}

private actor BlockingStatsLeaseClient: RemoteConnectionLeaseClient {
    private var disconnects = 0
    private var didStartDisconnect = false
    private var didReleaseDisconnect = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func disconnect() async {
        disconnects += 1
        didStartDisconnect = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        await waitUntilDisconnectReleased()
    }

    func disconnectCount() -> Int {
        disconnects
    }

    func waitUntilDisconnectStarted() async {
        if didStartDisconnect { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func releaseDisconnect() {
        didReleaseDisconnect = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func execute(_ command: String, timeout: Duration?) async throws -> String {
        ""
    }

    func upload(
        _ data: Data,
        to remotePath: String,
        permissions: Int32,
        strategy: SSHUploadStrategy
    ) async throws {}

    func remoteEnvironment(forceRefresh: Bool) async -> RemoteEnvironment {
        .fallbackPOSIX
    }

    func remoteTerminalType(forceRefresh: Bool) async -> RemoteTerminalType {
        .xterm256Color
    }

    private func waitUntilDisconnectReleased() async {
        if didReleaseDisconnect { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }
}

private actor ScriptedStatsLeaseClient: RemoteConnectionLeaseClient {
    private var commands: [String] = []

    func disconnect() async {}

    func execute(_ command: String, timeout: Duration?) async throws -> String {
        commands.append(command)

        if command.contains("uname -srm") {
            return "Linux 6.8 arm64\n---SEP---\nexecutor-host\n---SEP---\n8\n"
        }

        if command.contains("/proc/stat") {
            return """
                cpu  100 0 100 800 0 0 0 0
                ---SEP---
                MemTotal:       1000000 kB
                MemFree:         200000 kB
                MemAvailable:    600000 kB
                Buffers:          10000 kB
                Cached:          300000 kB
                ---SEP---
                Inter-|   Receive                                                |  Transmit
                 eth0: 1000 0 0 0 0 0 0 0 2000 0 0 0 0 0 0 0
                ---SEP---
                0.10 0.20 0.30 1/100 12345
                ---SEP---
                1000.00 0.00
                ---SEP---
                42
                """
        }

        if command.contains("df -BM") {
            return "/dev/disk 100M 20M 80M 20% /\n"
        }

        if command.contains("ps aux") {
            return """
                USER PID %CPU %MEM COMMAND
                root 1 1.0 0.1 init
                """
        }

        return ""
    }

    func upload(
        _ data: Data,
        to remotePath: String,
        permissions: Int32,
        strategy: SSHUploadStrategy
    ) async throws {}

    func remoteEnvironment(forceRefresh: Bool) async -> RemoteEnvironment {
        RemoteEnvironment(
            platform: .linux,
            shellProfile: .posix(shellName: "sh"),
            activeShellName: "sh",
            powerShellExecutable: nil
        )
    }

    func remoteTerminalType(forceRefresh: Bool) async -> RemoteTerminalType {
        .xterm256Color
    }

    func commandCount() -> Int {
        commands.count
    }
}

private actor AsyncFlag {
    private var marked = false

    func mark() {
        marked = true
    }

    func isMarked() -> Bool {
        marked
    }
}
