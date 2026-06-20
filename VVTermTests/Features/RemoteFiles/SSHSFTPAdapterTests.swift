import Foundation
import Testing
@testable import VVTerm

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
        var providerCallCount = 0
        let adapter = SSHSFTPAdapter(
            borrowedLeaseProvider: { _ in
                providerCallCount += 1
                return RemoteConnectionLease(client: borrowedClient, ownership: .borrowed)
            },
            credentialsProvider: { server in makeCredentials(serverId: server.id) },
            ownedClientFactory: { RecordingSFTPClient(homeDirectory: "/owned") }
        )

        let home = try await adapter.withService(for: server) { service in
            try await service.resolveHomeDirectory()
        }

        #expect(providerCallCount == 1, "RemoteFiles should ask for a borrowed lease instead of constructing one from a raw client")
        #expect(home == "/lease-boundary", "RemoteFiles should use the client carried by the borrowed lease")
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

    private func makeServer() -> Server {
        Server(
            workspaceId: UUID(),
            name: "RemoteFiles",
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

private enum RemoteFileTestError: Error {
    case expectedFailure
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

    func listDirectory(at path: String, maxEntries: Int?) async throws -> [RemoteFileEntry] {
        []
    }

    func stat(at path: String) async throws -> RemoteFileEntry {
        makeEntry(path: path)
    }

    func lstat(at path: String) async throws -> RemoteFileEntry {
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

    func fileSystemStatus(at path: String) async throws -> RemoteFileFilesystemStatus {
        RemoteFileFilesystemStatus(
            blockSize: 1,
            totalBlocks: 0,
            freeBlocks: 0,
            availableBlocks: 0
        )
    }

    private func makeEntry(path: String) -> RemoteFileEntry {
        RemoteFileEntry(
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
