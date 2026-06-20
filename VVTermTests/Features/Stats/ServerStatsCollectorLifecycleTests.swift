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
    func stopCollectingAndWaitAwaitsOwnedLeaseDisconnect() async throws {
        let server = makeServer()
        let client = BlockingStatsLeaseClient()
        let collector = makeCollector(
            connectionFactory: OneShotStatsConnectionFactory([
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
        let factory = OneShotStatsConnectionFactory([
            .init(lease: RemoteConnectionLease(client: firstClient, ownership: .owned)),
            .init(lease: RemoteConnectionLease(client: secondClient, ownership: .owned))
        ])
        let collector = makeCollector(connectionFactory: factory)

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
    func stopCollectingDoesNotDisconnectBorrowedSharedClient() async throws {
        let server = makeServer()
        let client = RecordingStatsLeaseClient()
        let collector = makeCollector(
            connectionFactory: OneShotStatsConnectionFactory([
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
        let factory = OneShotStatsConnectionFactory([
            .init(lease: RemoteConnectionLease(client: failedClient, ownership: .owned)),
            .init(lease: RemoteConnectionLease(client: retryClient, ownership: .owned))
        ])
        let collector = makeCollector(
            connectionFactory: factory,
            collectionTaskFactory: { collector, _, _, connection in
                Task {
                    await collector.beginCollectionTeardown()
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
            connectionFactory: OneShotStatsConnectionFactory([
                .init(lease: RemoteConnectionLease(client: client, ownership: .owned))
            ]),
            collectionTaskFactory: { collector, _, _, connection in
                Task {
                    await collector.recordCollectionFailure(CancellationError())
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

    private func makeCollector(
        connectionFactory: OneShotStatsConnectionFactory,
        collectionTaskFactory: ServerStatsCollector.CollectionTaskFactory? = nil
    ) -> ServerStatsCollector {
        ServerStatsCollector(
            connectionFactory: { server, sharedClient in
                connectionFactory.nextConnection(server: server, sharedClient: sharedClient)
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
private final class OneShotStatsConnectionFactory {
    private var connections: [ServerStatsCollector.StatsConnection]
    private(set) var callCount = 0

    init(_ connections: [ServerStatsCollector.StatsConnection]) {
        self.connections = connections
    }

    func nextConnection(
        server: Server,
        sharedClient: SSHClient?
    ) -> ServerStatsCollector.StatsConnection {
        callCount += 1
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

private actor AsyncFlag {
    private var marked = false

    func mark() {
        marked = true
    }

    func isMarked() -> Bool {
        marked
    }
}
