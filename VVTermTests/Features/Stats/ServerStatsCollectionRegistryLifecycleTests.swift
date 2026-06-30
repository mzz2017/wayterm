import Foundation
import Testing
@testable import VVTerm

// Test Context:
// These tests protect the Application-level owner for server Stats collectors.
// SwiftUI may ask for a collector and send visibility/retry intent, but the
// registry owns collector identity and cleanup. Fakes perform no network,
// keychain, or filesystem I/O. Update these tests only if Stats collector
// ownership intentionally moves to an equivalent non-UI owner.
@MainActor
struct ServerStatsCollectionRegistryLifecycleTests {
    @Test
    func registryOwnsOneCollectorPerServerAndAwaitsCleanup() async throws {
        let server = makeServer()
        let client = BlockingRegistryStatsLeaseClient()
        let factory = RegistryStatsConnectionFactory([
            .init(lease: RemoteConnectionLease(client: client, ownership: .owned))
        ])
        var madeCollectorCount = 0
        let registry = ServerStatsCollectionRegistry(
            collectorFactory: {
                madeCollectorCount += 1
                return makeCollector(ownedConnectionFactory: factory)
            }
        )

        // Given Stats UI asks for the server collector more than once.
        let firstCollector = registry.collector(for: server.id)
        let secondCollector = registry.collector(for: server.id)

        // Then the Application registry owns one stable collector lifetime for
        // that server instead of letting each UI render create a new collector.
        #expect(firstCollector === secondCollector)
        #expect(madeCollectorCount == 1)

        // When that collector has an active owned lease.
        await firstCollector.startCollecting(for: server)

        // Then registry cleanup remains awaitable until collector teardown and
        // lease close complete.
        let cleanupCompletion = RegistryAsyncFlag()
        let cleanupTask = Task {
            await registry.disconnect(serverId: server.id)
            await cleanupCompletion.mark()
        }

        await client.waitUntilDisconnectStarted()
        try await Task.sleep(for: .milliseconds(20))
        #expect(
            await cleanupCompletion.isMarked() == false,
            "Stats registry disconnect must wait for the owned collector lease to close."
        )

        await client.releaseDisconnect()
        await cleanupTask.value

        let replacementCollector = registry.collector(for: server.id)
        #expect(replacementCollector !== firstCollector)
        #expect(madeCollectorCount == 2)
        #expect(
            await client.disconnectCount() == 1,
            "Stats registry cleanup should close the owned collector lease exactly once."
        )
    }

    @Test
    func disconnectAllAwaitsEveryCollectorCleanupAndRemovesOwners() async throws {
        let firstServer = makeServer(name: "Stats 1")
        let secondServer = makeServer(name: "Stats 2")
        let firstClient = BlockingRegistryStatsLeaseClient()
        let secondClient = BlockingRegistryStatsLeaseClient()
        let factory = RegistryStatsConnectionFactory([
            .init(lease: RemoteConnectionLease(client: firstClient, ownership: .owned)),
            .init(lease: RemoteConnectionLease(client: secondClient, ownership: .owned))
        ])
        var madeCollectorCount = 0
        let registry = ServerStatsCollectionRegistry(
            collectorFactory: {
                madeCollectorCount += 1
                return makeCollector(ownedConnectionFactory: factory)
            }
        )

        // Given multiple Stats collectors have active owned leases.
        let firstCollector = registry.collector(for: firstServer.id)
        let secondCollector = registry.collector(for: secondServer.id)
        await firstCollector.startCollecting(for: firstServer)
        await secondCollector.startCollecting(for: secondServer)

        // When app-level teardown asks the registry to disconnect everything.
        let cleanupCompletion = RegistryAsyncFlag()
        let cleanupTask = Task {
            await registry.disconnectAll()
            await cleanupCompletion.mark()
        }

        await firstClient.waitUntilDisconnectStarted()
        await secondClient.waitUntilDisconnectStarted()
        try await Task.sleep(for: .milliseconds(20))
        #expect(
            await cleanupCompletion.isMarked() == false,
            "Stats registry disconnectAll must wait for every owned collector lease to close."
        )

        await firstClient.releaseDisconnect()
        await secondClient.releaseDisconnect()
        await cleanupTask.value

        // Then every collector owner is removed after its teardown completes.
        let firstReplacement = registry.collector(for: firstServer.id)
        let secondReplacement = registry.collector(for: secondServer.id)
        #expect(firstReplacement !== firstCollector)
        #expect(secondReplacement !== secondCollector)
        #expect(madeCollectorCount == 4)
        #expect(await firstClient.disconnectCount() == 1)
        #expect(await secondClient.disconnectCount() == 1)
    }

    @Test
    func collectorRequestedDuringDisconnectRemainsRegistryOwned() async throws {
        let server = makeServer()
        let firstClient = BlockingRegistryStatsLeaseClient()
        let secondClient = RecordingRegistryStatsLeaseClient()
        let factory = RegistryStatsConnectionFactory([
            .init(lease: RemoteConnectionLease(client: firstClient, ownership: .owned)),
            .init(lease: RemoteConnectionLease(client: secondClient, ownership: .owned))
        ])
        var madeCollectorCount = 0
        let registry = ServerStatsCollectionRegistry(
            collectorFactory: {
                madeCollectorCount += 1
                return makeCollector(ownedConnectionFactory: factory)
            }
        )

        // Given registry-owned Stats cleanup is waiting for the old collector's
        // owned lease to close.
        let oldCollector = registry.collector(for: server.id)
        await oldCollector.startCollecting(for: server)
        let disconnectTask = Task {
            await registry.disconnect(serverId: server.id)
        }
        await firstClient.waitUntilDisconnectStarted()

        // When UI asks for the same server collector during that teardown and
        // sends a fresh visible/retry start intent.
        let replacementDuringDisconnect = registry.collector(for: server.id)
        let restartTask = Task {
            await replacementDuringDisconnect.startCollecting(for: server)
        }
        try await Task.sleep(for: .milliseconds(20))

        // Then the replacement must already be the registry-owned collector
        // rather than a restart queued on the old tearing-down owner.
        #expect(replacementDuringDisconnect !== oldCollector)
        #expect(registry.collector(for: server.id) === replacementDuringDisconnect)
        #expect(factory.callCount == 2)

        await firstClient.releaseDisconnect()
        await restartTask.value
        await disconnectTask.value

        #expect(
            registry.collector(for: server.id) === replacementDuringDisconnect,
            "Registry disconnect must not orphan a collector that was requested while the old owner was tearing down."
        )
        #expect(madeCollectorCount == 2)
        #expect(await firstClient.disconnectCount() == 1)
        #expect(
            await secondClient.disconnectCount() == 0,
            "Fresh Stats collection created during old-owner teardown should remain active and registry-owned."
        )
    }

    private func makeCollector(
        ownedConnectionFactory: RegistryStatsConnectionFactory
    ) -> ServerStatsCollector {
        ServerStatsCollector(
            connectionProvider: StatsConnectionProvider { server, credentials in
                ownedConnectionFactory.nextConnection(server: server, credentials: credentials)
            },
            credentialsProvider: { server in
                makeCredentials(serverId: server.id)
            },
            collectionTaskFactory: { _, _, _, _ in
                Task {
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(10))
                    }
                }
            }
        )
    }

    private func makeServer(name: String = "Stats") -> Server {
        Server(
            workspaceId: UUID(),
            name: name,
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

@MainActor
private final class RegistryStatsConnectionFactory {
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
            return .init(lease: RemoteConnectionLease(client: RecordingRegistryStatsLeaseClient(), ownership: .owned))
        }

        return connections.removeFirst()
    }
}

private actor RecordingRegistryStatsLeaseClient: RemoteConnectionLeaseClient {
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

private actor BlockingRegistryStatsLeaseClient: RemoteConnectionLeaseClient {
    private var disconnects = 0
    private var disconnectStartedContinuations: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func disconnect() async {
        disconnects += 1
        let startedContinuations = disconnectStartedContinuations
        disconnectStartedContinuations.removeAll()
        startedContinuations.forEach { $0.resume() }

        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilDisconnectStarted() async {
        guard disconnects == 0 else { return }
        await withCheckedContinuation { continuation in
            disconnectStartedContinuations.append(continuation)
        }
    }

    func releaseDisconnect() {
        releaseContinuation?.resume()
        releaseContinuation = nil
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

private actor RegistryAsyncFlag {
    private var marked = false

    func mark() {
        marked = true
    }

    func isMarked() -> Bool {
        marked
    }
}
