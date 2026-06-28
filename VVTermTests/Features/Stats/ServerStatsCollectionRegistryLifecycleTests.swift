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
    func disconnect() async {}

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
