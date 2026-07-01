import Foundation
import Testing
@testable import Waterm

// Test Context:
// These tests protect RemoteFiles' SSH/SFTP ownership boundary. The adapter may
// borrow a terminal-owned connection or create an owned fallback connection, but
// SFTP work must run through the lease gate and disconnect must wait for
// accepted in-flight work before closing owned resources. Fakes are actor based
// and perform no network, keychain, or filesystem I/O. Update these tests only
// if RemoteFiles intentionally changes its connection ownership model.
@MainActor
struct SSHSFTPAdapterTests {
    @Test
    func defaultAdapterUsesOwnedClientInsteadOfTerminalSessionSingletons() async throws {
        let server = makeServer(host: "127.0.0.1", port: 1)
        let manager = ConnectionSessionManager.shared
        await manager.resetForTesting()

        let terminalSession = ConnectionSession(
            serverId: server.id,
            title: "Terminal-owned",
            connectionState: .connected
        )
        manager.sessions = [terminalSession]
        manager.selectedSessionId = terminalSession.id
        manager.registerSSHClient(
            SSHClient(),
            shellId: UUID(),
            for: terminalSession.id,
            serverId: server.id,
            skipTmuxLifecycle: true
        )

        let ownedClient = RecordingSFTPClient(homeDirectory: "/owned-boundary")
        let adapter = SSHSFTPAdapter(
            credentialsProvider: { server in makeCredentials(serverId: server.id) },
            ownedClientFactory: { ownedClient }
        )

        do {
            let home = try await adapter.withService(for: server) { service in
                try await service.resolveHomeDirectory()
            }

            #expect(
                home == "/owned-boundary",
                "RemoteFiles infrastructure defaults must not consult TerminalSessions singletons for borrowed leases."
            )
            await adapter.disconnect(serverId: server.id)
            await manager.resetForTesting()
        } catch {
            await adapter.disconnect(serverId: server.id)
            await manager.resetForTesting()
            throw error
        }
    }

    @Test
    func borrowedClientDisconnectDoesNotCloseTerminalOwnedClient() async throws {
        let server = makeServer()
        let borrowedClient = RecordingSFTPClient()
        let adapter = SSHSFTPAdapter(
            borrowedLeaseProvider: { _ in RemoteConnectionLease(client: borrowedClient, ownership: .borrowed) },
            credentialsProvider: { server in makeCredentials(serverId: server.id) },
            ownedClientFactory: { RecordingSFTPClient() }
        )

        _ = try await adapter.withService(for: server) { service in
            try await service.resolveHomeDirectory()
        }
        await adapter.disconnect(serverId: server.id)

        let disconnects = await borrowedClient.disconnectCount()
        #expect(disconnects == 0, "Borrowed RemoteFiles leases must leave terminal-owned clients connected")
    }

    @Test
    func borrowedLeaseProviderIsTheRemoteFilesConnectionBoundary() async throws {
        let server = makeServer()
        let borrowedClient = RecordingSFTPClient(homeDirectory: "/lease-boundary")
        let probe = BorrowedLeaseProviderProbe()
        let adapter = SSHSFTPAdapter(
            borrowedLeaseProvider: { _ in
                probe.callCount += 1
                return RemoteConnectionLease(client: borrowedClient, ownership: .borrowed)
            },
            credentialsProvider: { server in makeCredentials(serverId: server.id) },
            ownedClientFactory: { RecordingSFTPClient(homeDirectory: "/owned") }
        )

        let home = try await adapter.withService(for: server) { service in
            try await service.resolveHomeDirectory()
        }

        #expect(probe.callCount == 1, "RemoteFiles should ask for a borrowed lease instead of constructing one from a raw client")
        #expect(home == "/lease-boundary", "RemoteFiles should use the client carried by the borrowed lease")
    }

    @Test
    func replacingOwnedFallbackWithBorrowedLeaseClosesOwnedClient() async throws {
        let server = makeServer()
        let ownedClient = RecordingSFTPClient(homeDirectory: "/owned")
        let borrowedClient = RecordingSFTPClient(homeDirectory: "/borrowed")
        let probe = BorrowedLeaseProviderProbe()
        let adapter = SSHSFTPAdapter(
            borrowedLeaseProvider: { _ in
                probe.isAvailable
                    ? RemoteConnectionLease(client: borrowedClient, ownership: .borrowed)
                    : nil
            },
            credentialsProvider: { server in makeCredentials(serverId: server.id) },
            ownedClientFactory: { ownedClient }
        )

        // Given RemoteFiles first opens an owned fallback SFTP client before a
        // terminal-owned borrowed lease is available for the same server.
        let ownedHome = try await adapter.withService(for: server) { service in
            try await service.resolveHomeDirectory()
        }
        #expect(ownedHome == "/owned")

        // When a later operation can borrow the terminal-owned client.
        probe.isAvailable = true
        let borrowedHome = try await adapter.withService(for: server) { service in
            try await service.resolveHomeDirectory()
        }

        // Then the adapter closes the superseded owned fallback instead of
        // losing its registration and leaking its SSH/SFTP connection.
        #expect(borrowedHome == "/borrowed")
        #expect(
            await ownedClient.disconnectCount() == 1,
            "Replacing an owned RemoteFiles fallback with a borrowed lease must close the owned client."
        )
        #expect(
            await borrowedClient.disconnectCount() == 0,
            "Borrowed replacement remains terminal-owned and must not be closed by the replacement step."
        )
    }

    @Test
    func disconnectWaitsForInFlightOwnedSFTPOperationBeforeClosingClient() async throws {
        let server = makeServer()
        let ownedClient = RecordingSFTPClient()
        let blocker = BlockingOperationProbe()
        let adapter = SSHSFTPAdapter(
            borrowedLeaseProvider: { _ in nil },
            credentialsProvider: { server in makeCredentials(serverId: server.id) },
            ownedClientFactory: { ownedClient }
        )

        let operationTask = Task {
            try await adapter.withService(for: server) { _ in
                await blocker.markStarted()
                await blocker.waitUntilReleased()
            }
        }

        await blocker.waitUntilStarted()
        let disconnectTask = Task {
            await adapter.disconnect(serverId: server.id)
        }

        try await Task.sleep(for: .milliseconds(20))
        let disconnectsBeforeRelease = await ownedClient.disconnectCount()
        #expect(disconnectsBeforeRelease == 0, "Owned SFTP disconnect must wait for accepted in-flight work")

        await blocker.release()
        try await operationTask.value
        await disconnectTask.value

        let disconnectsAfterRelease = await ownedClient.disconnectCount()
        #expect(disconnectsAfterRelease == 1, "Owned SFTP lease should disconnect once after in-flight work completes")
    }

    @Test
    func concurrentOperationsForSameServerAreSerializedThroughOneLease() async throws {
        let server = makeServer()
        let ownedClient = RecordingSFTPClient()
        let probe = ExclusiveOperationProbe()
        let adapter = SSHSFTPAdapter(
            borrowedLeaseProvider: { _ in nil },
            credentialsProvider: { server in makeCredentials(serverId: server.id) },
            ownedClientFactory: { ownedClient }
        )

        async let first: Void = adapter.withService(for: server) { _ in
            await probe.runOperation()
        }
        async let second: Void = adapter.withService(for: server) { _ in
            await probe.runOperation()
        }

        try await first
        try await second

        let maxActiveOperations = await probe.maxActiveOperations()
        #expect(maxActiveOperations == 1, "SFTP operations for one server must not overlap on one libssh2 client")
    }

    @Test
    func failedBorrowedOperationDropsBorrowedRegistrationBeforeRetry() async throws {
        let server = makeServer()
        let firstClient = RecordingSFTPClient(homeDirectory: "/first")
        let secondClient = RecordingSFTPClient(homeDirectory: "/second")
        let provider = BorrowedClientSequence([firstClient, secondClient])
        let adapter = SSHSFTPAdapter(
            borrowedLeaseProvider: { _ in provider.nextLease() },
            credentialsProvider: { server in makeCredentials(serverId: server.id) },
            ownedClientFactory: { RecordingSFTPClient() }
        )

        await #expect(throws: RemoteFileTestError.expectedFailure) {
            _ = try await adapter.withService(for: server) { _ in
                throw RemoteFileTestError.expectedFailure
            }
        }

        let home = try await adapter.withService(for: server) { service in
            try await service.resolveHomeDirectory()
        }

        let providerCalls = provider.callCount
        #expect(providerCalls == 2, "Failed borrowed registrations must be dropped so retry can borrow the current terminal client")
        #expect(home == "/second", "Retry should use the replacement borrowed client after a borrowed operation failure")
    }

    @Test
    func staleBorrowedFailureDoesNotDropNewOwnedRegistration() async throws {
        let server = makeServer()
        let borrowedClient = RecordingSFTPClient(homeDirectory: "/borrowed")
        let ownedClient = RecordingSFTPClient(homeDirectory: "/owned")
        let provider = BorrowedClientSequence([borrowedClient])
        let blocker = BlockingOperationProbe()
        let adapter = SSHSFTPAdapter(
            borrowedLeaseProvider: { _ in provider.nextLease() },
            credentialsProvider: { server in makeCredentials(serverId: server.id) },
            ownedClientFactory: { ownedClient }
        )

        // Given a borrowed operation is in flight and a later operation is
        // waiting to replace that borrowed registration with an owned fallback.
        let failingBorrowedTask = Task {
            do {
                _ = try await adapter.withService(for: server) { _ in
                    await blocker.markStarted()
                    await blocker.waitUntilReleased()
                    throw RemoteFileTestError.expectedFailure
                }
                return false
            } catch RemoteFileTestError.expectedFailure {
                return true
            } catch {
                return false
            }
        }
        await blocker.waitUntilStarted()

        let ownedTask = Task {
            try await adapter.withService(for: server) { service in
                try await service.resolveHomeDirectory()
            }
        }
        try? await Task.sleep(for: .milliseconds(20))

        // When the old borrowed operation fails while the replacement is being
        // installed.
        await blocker.release()
        let borrowedFailed = await failingBorrowedTask.value
        let ownedHome = try await ownedTask.value

        // Then the old borrowed catch must not remove the newer owned
        // registration; disconnect still has to close the owned client.
        #expect(borrowedFailed)
        #expect(ownedHome == "/owned")
        await adapter.disconnect(serverId: server.id)
        #expect(
            await ownedClient.disconnectCount() == 1,
            "A stale borrowed failure must not drop a newer owned registration before disconnect can close it."
        )
    }

    @Test
    func replacementInProgressSerializesLaterRegistrationRequests() async throws {
        let server = makeServer()
        let initialOwnedClient = RecordingSFTPClient(homeDirectory: "/owned-initial")
        let leakedOwnedCandidate = RecordingSFTPClient(homeDirectory: "/owned-candidate")
        let borrowedClient = RecordingSFTPClient(homeDirectory: "/borrowed")
        let ownedFactory = OwnedClientFactoryProbe([initialOwnedClient, leakedOwnedCandidate])
        let leaseSequence = BorrowedLeaseSequence([
            nil,
            RemoteConnectionLease(client: borrowedClient, ownership: .borrowed),
            nil
        ])
        let inFlightOperation = BlockingOperationProbe()
        let adapter = SSHSFTPAdapter(
            borrowedLeaseProvider: { _ in
                leaseSequence.nextLease()
            },
            credentialsProvider: { server in makeCredentials(serverId: server.id) },
            ownedClientFactory: { ownedFactory.nextClient() }
        )

        // Given an owned fallback operation is in flight when a borrowed lease
        // becomes available for the same server.
        let ownedTask = Task {
            try await adapter.withService(for: server) { _ in
                await inFlightOperation.markStarted()
                await inFlightOperation.waitUntilReleased()
            }
        }
        await inFlightOperation.waitUntilStarted()

        let firstReplacementTask = Task {
            try await adapter.withService(for: server) { service in
                try await service.resolveHomeDirectory()
            }
        }
        try await Task.sleep(for: .milliseconds(20))

        // When another operation arrives while the replacement is still waiting
        // for the old owned lease to close.
        let secondReplacementTask = Task {
            try await adapter.withService(for: server) { service in
                try await service.resolveHomeDirectory()
            }
        }

        await inFlightOperation.release()
        try await ownedTask.value
        let firstHome = try await firstReplacementTask.value
        let secondHome = try await secondReplacementTask.value

        // Then the later operation waits for the in-progress replacement rather
        // than installing another owned fallback that the first replacement can
        // overwrite and leak.
        #expect(firstHome == "/borrowed")
        #expect(secondHome == "/borrowed")
        #expect(
            ownedFactory.callCount == 1,
            "Replacement in progress must prevent later same-server requests from installing another owned client."
        )
        await adapter.disconnect(serverId: server.id)
        #expect(
            await leakedOwnedCandidate.disconnectCount() == 0,
            "The second owned candidate should never be registered during an in-progress replacement."
        )
    }

    @Test
    func disconnectDuringPendingBorrowedReplacementCancelsWaitingOperation() async throws {
        let server = makeServer()
        let initialOwnedClient = RecordingSFTPClient(homeDirectory: "/owned-initial")
        let borrowedClient = RecordingSFTPClient(homeDirectory: "/borrowed")
        let leaseSequence = BorrowedLeaseSequence([
            nil,
            RemoteConnectionLease(client: borrowedClient, ownership: .borrowed)
        ])
        let inFlightOperation = BlockingOperationProbe()
        let lateOperation = OperationStartProbe()
        let adapter = SSHSFTPAdapter(
            borrowedLeaseProvider: { _ in
                leaseSequence.nextLease()
            },
            credentialsProvider: { server in makeCredentials(serverId: server.id) },
            ownedClientFactory: { initialOwnedClient }
        )

        // Given a borrowed replacement is waiting for the old owned lease to
        // close before it can be installed.
        let ownedTask = Task {
            try await adapter.withService(for: server) { _ in
                await inFlightOperation.markStarted()
                await inFlightOperation.waitUntilReleased()
            }
        }
        await inFlightOperation.waitUntilStarted()

        let replacementTask = Task {
            do {
                _ = try await adapter.withService(for: server) { _ in
                    await lateOperation.markStarted()
                }
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }
        try await Task.sleep(for: .milliseconds(20))

        // When RemoteFiles disconnects the server before the replacement is
        // installed.
        let disconnectTask = Task {
            await adapter.disconnect(serverId: server.id)
        }
        await inFlightOperation.release()
        try await ownedTask.value
        await disconnectTask.value
        let wasCanceled = await replacementTask.value

        // Then the waiting operation is canceled instead of running on a
        // borrowed lease after disconnect has returned.
        #expect(wasCanceled)
        #expect(
            !(await lateOperation.didStart()),
            "A pending borrowed replacement must not run a waiting SFTP operation after disconnect wins."
        )
        #expect(
            await initialOwnedClient.disconnectCount() == 1,
            "Disconnect during pending replacement should still close the superseded owned client."
        )
    }

    private func makeServer(
        host: String = "example.com",
        port: Int = 22
    ) -> Server {
        Server(
            workspaceId: UUID(),
            name: "RemoteFiles",
            host: host,
            port: port,
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

private enum RemoteFileTestError: Error {
    case expectedFailure
}

@MainActor
private final class BorrowedLeaseProviderProbe {
    var callCount = 0
    var isAvailable = false
}

@MainActor
private final class BorrowedClientSequence {
    private var clients: [RecordingSFTPClient]
    private(set) var callCount = 0

    init(_ clients: [RecordingSFTPClient]) {
        self.clients = clients
    }

    func nextLease() -> RemoteConnectionLease? {
        callCount += 1
        guard !clients.isEmpty else { return nil }
        return RemoteConnectionLease(client: clients.removeFirst(), ownership: .borrowed)
    }
}

@MainActor
private final class OwnedClientFactoryProbe {
    private var clients: [RecordingSFTPClient]
    private(set) var callCount = 0

    init(_ clients: [RecordingSFTPClient]) {
        self.clients = clients
    }

    func nextClient() -> RecordingSFTPClient {
        callCount += 1
        guard !clients.isEmpty else {
            return RecordingSFTPClient(homeDirectory: "/unexpected-owned")
        }
        return clients.removeFirst()
    }
}

@MainActor
private final class BorrowedLeaseSequence {
    private var leases: [RemoteConnectionLease?]

    init(_ leases: [RemoteConnectionLease?]) {
        self.leases = leases
    }

    func nextLease() -> RemoteConnectionLease? {
        guard !leases.isEmpty else { return nil }
        return leases.removeFirst()
    }
}

private actor RecordingSFTPClient: SFTPRemoteFileClient {
    private var connects = 0
    private var disconnects = 0
    private let homeDirectory: String

    init(homeDirectory: String = "/home/test") {
        self.homeDirectory = homeDirectory
    }

    func connectForRemoteFileLease(to server: Server, credentials: ServerCredentials) async throws {
        connects += 1
    }

    func disconnect() async {
        disconnects += 1
    }

    func disconnectCount() -> Int {
        disconnects
    }

    func execute(_ command: String, timeout: Duration?) async throws -> String {
        ""
    }

    func remoteEnvironment(forceRefresh: Bool) async -> RemoteEnvironment {
        .fallbackPOSIX
    }

    func remoteTerminalType(forceRefresh: Bool) async -> RemoteTerminalType {
        .xterm256Color
    }

    func listDirectory(at path: String, maxEntries: Int?) async throws -> [SSHFileTransferEntry] {
        []
    }

    func stat(at path: String) async throws -> SSHFileTransferEntry {
        makeEntry(path: path)
    }

    func lstat(at path: String) async throws -> SSHFileTransferEntry {
        makeEntry(path: path)
    }

    func readFile(at path: String, maxBytes: Int) async throws -> Data {
        Data()
    }

    func downloadFile(at path: String, to localURL: URL) async throws {}

    func upload(
        _ data: Data,
        to remotePath: String,
        permissions: Int32,
        strategy: SSHUploadStrategy
    ) async throws {}

    func createDirectory(at path: String, permissions: Int32) async throws {}

    func renameItem(at sourcePath: String, to destinationPath: String) async throws {}

    func deleteFile(at path: String) async throws {}

    func deleteDirectory(at path: String) async throws {}

    func setPermissions(at path: String, permissions: UInt32) async throws {}

    func resolveHomeDirectory() async throws -> String {
        homeDirectory
    }

    func fileSystemStatus(at path: String) async throws -> SSHFileTransferFilesystemStatus {
        SSHFileTransferFilesystemStatus(
            blockSize: 1,
            totalBlocks: 0,
            freeBlocks: 0,
            availableBlocks: 0
        )
    }

    private func makeEntry(path: String) -> SSHFileTransferEntry {
        SSHFileTransferEntry(
            name: URL(fileURLWithPath: path).lastPathComponent,
            path: path,
            type: .file,
            size: nil,
            modifiedAt: nil,
            permissions: nil,
            symlinkTarget: nil
        )
    }
}

private actor ExclusiveOperationProbe {
    private var activeOperations = 0
    private var maximumActiveOperations = 0

    func runOperation() async {
        activeOperations += 1
        maximumActiveOperations = max(maximumActiveOperations, activeOperations)
        try? await Task.sleep(for: .milliseconds(20))
        activeOperations -= 1
    }

    func maxActiveOperations() -> Int {
        maximumActiveOperations
    }
}

private actor BlockingOperationProbe {
    private var didStart = false
    private var didRelease = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func markStarted() {
        didStart = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func waitUntilStarted() async {
        if didStart { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func release() {
        didRelease = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func waitUntilReleased() async {
        if didRelease { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }
}

private actor OperationStartProbe {
    private var started = false

    func markStarted() {
        started = true
    }

    func didStart() -> Bool {
        started
    }
}
