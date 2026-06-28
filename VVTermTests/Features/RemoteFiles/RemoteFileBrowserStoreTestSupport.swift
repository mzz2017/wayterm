import Foundation
@testable import VVTerm

func makeRemoteFileBrowserEntry(name: String, path: String, type: RemoteFileType) -> RemoteFileEntry {
    RemoteFileEntry(
        name: name,
        path: path,
        type: type,
        size: nil,
        modifiedAt: nil,
        permissions: nil,
        symlinkTarget: nil
    )
}

func makeRemoteFileBrowserTab() -> RemoteFileTab {
    RemoteFileTab(serverId: UUID(), seedPath: "/tmp")
}

func makeRemoteFileBrowserServer() -> Server {
    Server(
        workspaceId: UUID(),
        name: "Production",
        host: "example.com",
        username: "root"
    )
}

func makeRemoteFileBrowserCredentials(serverId: UUID) -> ServerCredentials {
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

func makeRemoteFileBrowserDefaults() -> UserDefaults {
    let suiteName = "RemoteFileBrowserStoreTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
}

func makeRemoteFileBrowserPersistedStateStore(
    defaults: UserDefaults = makeRemoteFileBrowserDefaults()
) -> RemoteFileBrowserPersistedStateStore {
    RemoteFileBrowserPersistedStateStore(userDefaults: defaults)
}

@MainActor
func makeRemoteFileBrowserStore(
    server: Server,
    client: BlockingNavigationRemoteFileClient
) -> RemoteFileBrowserStore {
    RemoteFileBrowserStore(
        persistedStateStore: makeRemoteFileBrowserPersistedStateStore(),
        remoteFileServiceAccess: SSHSFTPAdapter(
            credentialsProvider: { server in makeRemoteFileBrowserCredentials(serverId: server.id) },
            ownedClientFactory: {
                client
            }
        ),
        serverProvider: { _ in nil }
    )
}

actor RemoteFileBrowserOperationProbe {
    private(set) var started = false

    func markStarted() {
        started = true
    }
}

struct RemoteFileMutationIntentFailure: Error {}

struct RemoteFileMoveDestinationLoadFailure: Error {}

extension Array where Element == Result<[RemoteFileEntry], Error> {
    func singleSuccess() throws -> [RemoteFileEntry] {
        guard count == 1, case .success(let entries) = self[0] else {
            throw RemoteFileMoveDestinationLoadFailure()
        }
        return entries
    }
}

actor RemoteFileMutationGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isReleased = false

    func wait() async {
        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func release() {
        isReleased = true
        continuation?.resume()
        continuation = nil
    }
}

actor RemoteFileWaitProbe {
    private(set) var didReturn = false

    func markReturned() {
        didReturn = true
    }
}

@MainActor
final class NonSerializingRemoteFileServiceAccess: RemoteFileServiceAccessing {
    private let client: any SFTPRemoteFileClient

    init(client: any SFTPRemoteFileClient) {
        self.client = client
    }

    func withService<T>(
        for server: Server,
        operation: @escaping (any RemoteFileService) async throws -> T
    ) async throws -> T {
        try await operation(SFTPRemoteFileService(client: client))
    }

    func disconnect(serverId: UUID) async {
        await client.disconnect()
    }

    func disconnectAll() async {
        await client.disconnect()
    }
}

actor BlockingDisconnectRemoteFileClient: SFTPRemoteFileClient {
    private var disconnectStarted = false
    private var disconnectWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var releaseRequested = false

    init() async {}

    func waitUntilDisconnectStarted() async {
        if disconnectStarted { return }
        await withCheckedContinuation { continuation in
            disconnectWaiters.append(continuation)
        }
    }

    func hasStartedDisconnect() -> Bool {
        disconnectStarted
    }

    func releaseDisconnect() {
        if let releaseContinuation {
            releaseContinuation.resume()
            self.releaseContinuation = nil
        } else {
            releaseRequested = true
        }
    }

    func connectForRemoteFileLease(to server: Server, credentials: ServerCredentials) async throws {}

    func disconnect() async {
        disconnectStarted = true
        for waiter in disconnectWaiters {
            waiter.resume()
        }
        disconnectWaiters.removeAll()
        guard !releaseRequested else { return }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func execute(_ command: String, timeout: Duration?) async throws -> String { "" }

    func remoteEnvironment(forceRefresh: Bool) async -> RemoteEnvironment { .fallbackPOSIX }

    func remoteTerminalType(forceRefresh: Bool) async -> RemoteTerminalType { .xterm256Color }

    func listDirectory(at path: String, maxEntries: Int?) async throws -> [SSHFileTransferEntry] { [] }

    func stat(at path: String) async throws -> SSHFileTransferEntry {
        makeEntry(path: path)
    }

    func lstat(at path: String) async throws -> SSHFileTransferEntry {
        makeEntry(path: path)
    }

    func readFile(at path: String, maxBytes: Int) async throws -> Data { Data() }

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

    func resolveHomeDirectory() async throws -> String { "/home/test" }

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

actor BlockingNavigationRemoteFileClient: SFTPRemoteFileClient {
    private var listResponses: [String: [RemoteFileEntry]]
    private var stats: [String: RemoteFileEntry]
    private var blockedListPaths: Set<String>
    private var blockedStatPaths: Set<String>
    private var releasedListPaths: Set<String> = []
    private var listStartedPaths: Set<String> = []
    private var listCounts: [String: Int] = [:]
    private var listStartedWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var listCountWaiters: [String: [(count: Int, continuation: CheckedContinuation<Void, Never>)]] = [:]
    private var listReleaseWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var releasedStatPaths: Set<String> = []
    private var statStartedPaths: Set<String> = []
    private var statStartedWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var statReleaseWaiters: [String: CheckedContinuation<Void, Never>] = [:]
    private let blocksDisconnect: Bool
    private var disconnectStarted = false
    private var disconnectWaiters: [CheckedContinuation<Void, Never>] = []
    private var disconnectReleaseContinuation: CheckedContinuation<Void, Never>?
    private var disconnectReleaseRequested = false

    init(
        listResponses: [String: [RemoteFileEntry]] = [:],
        stats: [String: RemoteFileEntry] = [:],
        blockedListPaths: Set<String> = [],
        blockedStatPaths: Set<String> = [],
        blocksDisconnect: Bool = false
    ) async {
        self.listResponses = listResponses
        self.stats = stats
        self.blockedListPaths = blockedListPaths
        self.blockedStatPaths = blockedStatPaths
        self.blocksDisconnect = blocksDisconnect
    }

    func waitUntilListStarted(path: String) async {
        let normalizedPath = Self.normalizePath(path)
        if listStartedPaths.contains(normalizedPath) { return }
        await withCheckedContinuation { continuation in
            listStartedWaiters[normalizedPath, default: []].append(continuation)
        }
    }

    func waitUntilListCount(path: String, count: Int) async {
        let normalizedPath = Self.normalizePath(path)
        if listCounts[normalizedPath, default: 0] >= count { return }
        await withCheckedContinuation { continuation in
            listCountWaiters[normalizedPath, default: []].append((count, continuation))
        }
    }

    func releaseList(path: String) {
        let normalizedPath = Self.normalizePath(path)
        releasedListPaths.insert(normalizedPath)
        for waiter in listReleaseWaiters.removeValue(forKey: normalizedPath) ?? [] {
            waiter.resume()
        }
    }

    func hasListed(path: String) -> Bool {
        listStartedPaths.contains(Self.normalizePath(path))
    }

    func listCount(path: String) -> Int {
        listCounts[Self.normalizePath(path)] ?? 0
    }

    func waitUntilStatStarted(path: String) async {
        let normalizedPath = Self.normalizePath(path)
        if statStartedPaths.contains(normalizedPath) { return }
        await withCheckedContinuation { continuation in
            statStartedWaiters[normalizedPath, default: []].append(continuation)
        }
    }

    func releaseStat(path: String) {
        let normalizedPath = Self.normalizePath(path)
        releasedStatPaths.insert(normalizedPath)
        statReleaseWaiters.removeValue(forKey: normalizedPath)?.resume()
    }

    func waitUntilDisconnectStarted() async {
        if disconnectStarted { return }
        await withCheckedContinuation { continuation in
            disconnectWaiters.append(continuation)
        }
    }

    func hasStartedDisconnect() -> Bool {
        disconnectStarted
    }

    func releaseDisconnect() {
        if let disconnectReleaseContinuation {
            disconnectReleaseContinuation.resume()
            self.disconnectReleaseContinuation = nil
        } else {
            disconnectReleaseRequested = true
        }
    }

    func connectForRemoteFileLease(to server: Server, credentials: ServerCredentials) async throws {}

    func disconnect() async {
        disconnectStarted = true
        for waiter in disconnectWaiters {
            waiter.resume()
        }
        disconnectWaiters.removeAll()
        guard blocksDisconnect, !disconnectReleaseRequested else { return }
        await withCheckedContinuation { continuation in
            disconnectReleaseContinuation = continuation
        }
    }

    func execute(_ command: String, timeout: Duration?) async throws -> String { "" }

    func remoteEnvironment(forceRefresh: Bool) async -> RemoteEnvironment { .fallbackPOSIX }

    func remoteTerminalType(forceRefresh: Bool) async -> RemoteTerminalType { .xterm256Color }

    func listDirectory(at path: String, maxEntries: Int?) async throws -> [SSHFileTransferEntry] {
        let normalizedPath = Self.normalizePath(path)
        listStartedPaths.insert(normalizedPath)
        listCounts[normalizedPath, default: 0] += 1
        for waiter in listStartedWaiters.removeValue(forKey: normalizedPath) ?? [] {
            waiter.resume()
        }
        let startedCount = listCounts[normalizedPath, default: 0]
        let waiters = listCountWaiters.removeValue(forKey: normalizedPath) ?? []
        var remainingWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
        for waiter in waiters {
            if startedCount >= waiter.count {
                waiter.continuation.resume()
            } else {
                remainingWaiters.append(waiter)
            }
        }
        if !remainingWaiters.isEmpty {
            listCountWaiters[normalizedPath] = remainingWaiters
        }

        if blockedListPaths.contains(normalizedPath), !releasedListPaths.contains(normalizedPath) {
            await withCheckedContinuation { continuation in
                listReleaseWaiters[normalizedPath, default: []].append(continuation)
            }
        }

        return (listResponses[normalizedPath] ?? []).map(SSHFileTransferEntry.init(remoteFileEntry:))
    }

    func stat(at path: String) async throws -> SSHFileTransferEntry {
        let normalizedPath = Self.normalizePath(path)
        statStartedPaths.insert(normalizedPath)
        for waiter in statStartedWaiters.removeValue(forKey: normalizedPath) ?? [] {
            waiter.resume()
        }

        if blockedStatPaths.contains(normalizedPath), !releasedStatPaths.contains(normalizedPath) {
            await withCheckedContinuation { continuation in
                statReleaseWaiters[normalizedPath] = continuation
            }
        }

        return stats[normalizedPath].map(SSHFileTransferEntry.init(remoteFileEntry:))
            ?? makeEntry(path: path, type: .file)
    }

    func lstat(at path: String) async throws -> SSHFileTransferEntry {
        makeEntry(path: path, type: .file)
    }

    func readFile(at path: String, maxBytes: Int) async throws -> Data { Data() }

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

    func resolveHomeDirectory() async throws -> String { "/home/test" }

    func fileSystemStatus(at path: String) async throws -> SSHFileTransferFilesystemStatus {
        SSHFileTransferFilesystemStatus(
            blockSize: 1,
            totalBlocks: 0,
            freeBlocks: 0,
            availableBlocks: 0
        )
    }

    private func makeEntry(path: String, type: SSHFileTransferEntryType) -> SSHFileTransferEntry {
        SSHFileTransferEntry(
            name: URL(fileURLWithPath: path).lastPathComponent,
            path: path,
            type: type,
            size: nil,
            modifiedAt: nil,
            permissions: nil,
            symlinkTarget: nil
        )
    }

    private nonisolated static func normalizePath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "/" }

        let basePath = trimmed.hasPrefix("/") ? trimmed : "/" + trimmed
        let components = basePath.split(separator: "/", omittingEmptySubsequences: false)
        var normalized: [Substring] = []

        for component in components {
            switch component {
            case "", ".":
                continue
            case "..":
                if !normalized.isEmpty {
                    normalized.removeLast()
                }
            default:
                normalized.append(component)
            }
        }

        return "/" + normalized.joined(separator: "/")
    }
}
