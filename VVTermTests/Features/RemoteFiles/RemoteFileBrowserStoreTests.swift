import Foundation
import Testing
@testable import VVTerm

// Test Context:
// These tests protect RemoteFiles browser state rules: entry filtering,
// per-tab persistence, initial path selection, directory/viewer request
// ordering, user mutation task ownership, and transfer task ownership. Fakes
// use in-memory UserDefaults suites, injected providers, and small ordering
// probes, so failures usually indicate a browser-state or lifecycle ownership
// regression unless the persisted snapshot model, path-precedence product rule,
// or application-layer request owner intentionally changes.
@MainActor
struct RemoteFileBrowserStoreTests {
    @Test
    func displayedEntriesHideDotFilesAndKeepDirectoryOrdering() {
        let defaults = makeDefaults()
        let store = RemoteFileBrowserStore(defaults: defaults)
        let tab = makeTab()

        store.updateState(for: tab) { state in
            state.entries = [
                makeEntry(name: ".secret", path: "/tmp/.secret", type: .file),
                makeEntry(name: "docs", path: "/tmp/docs", type: .directory),
                makeEntry(name: "readme.md", path: "/tmp/readme.md", type: .file)
            ]
            state.showHiddenFiles = false
            state.sort = .name
            state.sortDirection = .ascending
        }

        #expect(store.displayedEntries(for: tab).map(\.name) == ["docs", "readme.md"])
    }

    @Test
    func persistedStateLoadsIntoFreshStoreInstance() {
        let defaults = makeDefaults()
        let tab = makeTab()

        let store = RemoteFileBrowserStore(defaults: defaults)
        store.updateState(for: tab) { state in
            state.currentPath = "/srv/releases"
            state.sort = .size
            state.sortDirection = .ascending
            state.showHiddenFiles = true
            state.hasCustomizedHiddenFiles = true
        }
        store.persistState(for: tab.id)

        let reloadedStore = RemoteFileBrowserStore(defaults: defaults)
        let persisted = reloadedStore.persistedState(for: tab.id)

        #expect(persisted.lastVisitedPath == "/srv/releases")
        #expect(persisted.sort == .size)
        #expect(persisted.sortDirection == .ascending)
        #expect(persisted.showHiddenFiles)
        #expect(persisted.hasCustomizedHiddenFiles)
    }

    @Test
    func legacyServerScopedSnapshotIsDiscardedOnLoad() throws {
        let defaults = makeDefaults()
        let legacyKey = "remoteFileBrowserState.v1"
        let legacyPayload = try JSONEncoder().encode([
            UUID().uuidString: RemoteFileBrowserPersistedState(lastVisitedPath: "/legacy")
        ])
        defaults.set(legacyPayload, forKey: legacyKey)

        let store = RemoteFileBrowserStore(defaults: defaults)

        #expect(defaults.object(forKey: legacyKey) == nil)
        #expect(store.persistedStates.isEmpty)
    }

    @Test
    func initialDirectoryCandidatesPreferPersistedPathOverSeedPath() {
        let defaults = makeDefaults()
        let server = makeServer()
        let tab = RemoteFileTab(serverId: server.id, seedPath: "/etc")

        let store = RemoteFileBrowserStore(
            defaults: defaults,
            workingDirectoryProvider: { _ in "/srv/app" }
        )
        store.updateState(for: tab) { state in
            state.currentPath = "/etc/nginx"
        }
        store.persistState(for: tab.id)

        let reloadedStore = RemoteFileBrowserStore(
            defaults: defaults,
            workingDirectoryProvider: { _ in "/srv/app" }
        )
        let candidates = reloadedStore.initialDirectoryCandidates(
            for: server,
            tab: tab,
            initialPath: tab.seedPath
        )

        #expect(candidates == ["/etc/nginx", "/etc", "/srv/app"])
    }

    @Test
    func sameServerOperationWaitsForDroppedDisconnectTask() async throws {
        let defaults = makeDefaults()
        let server = makeServer()
        let disconnectingClient = BlockingDisconnectRemoteFileClient()
        let nextClient = BlockingDisconnectRemoteFileClient()
        var clients: [BlockingDisconnectRemoteFileClient] = [disconnectingClient, nextClient]
        let operationProbe = RemoteFileOperationProbe()
        let store = RemoteFileBrowserStore(
            defaults: defaults,
            remoteFileServiceAdapter: SSHSFTPAdapter(
                credentialsProvider: { server in makeCredentials(serverId: server.id) },
                ownedClientFactory: {
                    clients.removeFirst()
                }
            )
        )

        // Given RemoteFiles has an established service registration for a
        // server, and iOS sends disconnect intent without awaiting the returned
        // task.
        _ = try await store.withRemoteFileService(for: server) { service in
            try await service.resolveHomeDirectory()
        }
        _ = store.disconnect(serverId: server.id)
        await disconnectingClient.waitUntilDisconnectStarted()

        // When a later same-server operation starts while the disconnect is
        // still closing the previous lease.
        let operationTask = Task {
            try await store.withRemoteFileService(for: server) { _ in
                await operationProbe.markStarted()
            }
        }
        try await Task.sleep(for: .milliseconds(20))

        // Then the store must wait for the pending disconnect instead of
        // racing a new SFTP registration over teardown.
        #expect(
            await !operationProbe.started,
            "Same-server RemoteFiles operations must wait for a pending disconnect even if the caller dropped the disconnect task."
        )

        await disconnectingClient.releaseDisconnect()
        try await operationTask.value
        #expect(await operationProbe.started)
    }

    @Test
    func sameServerOperationWaitsForDisconnectRegisteredAfterFirstWait() async throws {
        let defaults = makeDefaults()
        let server = makeServer()
        let firstClient = BlockingDisconnectRemoteFileClient()
        let secondClient = BlockingDisconnectRemoteFileClient()
        let thirdClient = BlockingDisconnectRemoteFileClient()
        var clients: [BlockingDisconnectRemoteFileClient] = [firstClient, secondClient, thirdClient]
        let operationProbe = RemoteFileOperationProbe()
        let store = RemoteFileBrowserStore(
            defaults: defaults,
            remoteFileServiceAdapter: SSHSFTPAdapter(
                credentialsProvider: { server in makeCredentials(serverId: server.id) },
                ownedClientFactory: {
                    clients.removeFirst()
                }
            )
        )
        var insertedSecondDisconnect = false
        store.setPendingDisconnectWaitDidFinishForTesting { serverId in
            guard serverId == server.id, !insertedSecondDisconnect else { return }
            insertedSecondDisconnect = true
            store.setPendingDisconnectWaitDidFinishForTesting(nil)
            _ = try? await store.withRemoteFileService(for: server) { service in
                try await service.resolveHomeDirectory()
            }
            _ = store.disconnect(serverId: server.id)
            await secondClient.waitUntilDisconnectStarted()
        }

        // Given an operation is waiting for a dropped disconnect task.
        _ = try await store.withRemoteFileService(for: server) { service in
            try await service.resolveHomeDirectory()
        }
        _ = store.disconnect(serverId: server.id)
        await firstClient.waitUntilDisconnectStarted()
        let operationTask = Task {
            try await store.withRemoteFileService(for: server) { _ in
                await operationProbe.markStarted()
            }
        }

        // When the first disconnect finishes, another same-server disconnect
        // is registered before the waiting operation resumes service work.
        await firstClient.releaseDisconnect()
        try await Task.sleep(for: .milliseconds(20))

        // Then the waiting operation must re-check and wait for the second
        // pending disconnect too.
        #expect(
            await !operationProbe.started,
            "RemoteFiles should re-check pending disconnects after each awaited disconnect task."
        )

        await secondClient.releaseDisconnect()
        try await operationTask.value
        #expect(await operationProbe.started)
    }

    @Test
    func mutationRequestTracksTaskAndRunsSuccessAfterOperation() async throws {
        let store = RemoteFileBrowserStore(defaults: makeDefaults())
        let gate = RemoteFileMutationGate()
        var events: [String] = []

        // Given a RemoteFiles mutation launched from synchronous UI intent.
        let requestID = store.requestMutation(
            operation: {
                events.append("operation-started")
                await gate.wait()
                events.append("operation-finished")
                return "created"
            },
            onSuccess: { result in
                events.append("success-\(result)")
            },
            onFailure: { _ in
                events.append("failure")
            }
        )
        try await Task.sleep(for: .milliseconds(20))

        // Then the application store owns and exposes the pending mutation task
        // until the async operation finishes.
        #expect(store.pendingMutationRequestIDs.contains(requestID))
        #expect(events == ["operation-started"])

        await gate.release()
        await store.waitForMutationRequest(requestID)

        #expect(!store.pendingMutationRequestIDs.contains(requestID))
        #expect(events == ["operation-started", "operation-finished", "success-created"])
    }

    @Test
    func mutationRequestTracksFailureAndSkipsSuccessContinuation() async throws {
        let store = RemoteFileBrowserStore(defaults: makeDefaults())
        var events: [String] = []

        // Given a RemoteFiles mutation whose async operation fails before it
        // can safely update UI state.
        let requestID = store.requestMutation(
            operation: {
                events.append("operation-started")
                throw RemoteFileMutationIntentFailure()
            },
            onSuccess: {
                events.append("success")
            },
            onFailure: { error in
                events.append("failure-\(type(of: error))")
            }
        )
        await store.waitForMutationRequest(requestID)

        // Then the application store keeps the failure path ordered and removes
        // the tracked request only after the failure handler runs.
        #expect(!store.pendingMutationRequestIDs.contains(requestID))
        #expect(events == ["operation-started", "failure-RemoteFileMutationIntentFailure"])
    }

    @Test
    func transferRequestTracksTaskProgressAndSuccessAfterOperation() async throws {
        let store = RemoteFileBrowserStore(defaults: makeDefaults())
        let gate = RemoteFileMutationGate()
        var events: [String] = []

        // Given a RemoteFiles transfer launched from synchronous UI intent.
        let requestID = store.requestTransfer(
            operation: { onProgress in
                events.append("operation-started")
                onProgress(RemoteFileBrowserStore.TransferProgress(
                    completedUnitCount: 1,
                    totalUnitCount: 2,
                    currentItemName: "logs.txt"
                ))
                await gate.wait()
                events.append("operation-finished")
                return "exported"
            },
            onProgress: { progress in
                events.append("progress-\(progress.completedUnitCount)-\(progress.totalUnitCount)-\(progress.currentItemName)")
            },
            onSuccess: { result in
                events.append("success-\(result)")
            },
            onFailure: { _ in
                events.append("failure")
            }
        )
        try await Task.sleep(for: .milliseconds(20))

        // Then the application store owns the transfer task until the async
        // operation and success continuation finish.
        #expect(store.pendingTransferRequestIDs.contains(requestID))
        #expect(events == ["operation-started", "progress-1-2-logs.txt"])

        await gate.release()
        await store.waitForTransferRequest(requestID)

        #expect(!store.pendingTransferRequestIDs.contains(requestID))
        #expect(events == [
            "operation-started",
            "progress-1-2-logs.txt",
            "operation-finished",
            "success-exported"
        ])
    }

    private func makeEntry(name: String, path: String, type: RemoteFileType) -> RemoteFileEntry {
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

    private func makeTab() -> RemoteFileTab {
        RemoteFileTab(serverId: UUID(), seedPath: "/tmp")
    }

    private func makeServer() -> Server {
        Server(
            workspaceId: UUID(),
            name: "Production",
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

    private func makeDefaults() -> UserDefaults {
        let suiteName = "RemoteFileBrowserStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

private actor RemoteFileOperationProbe {
    private(set) var started = false

    func markStarted() {
        started = true
    }
}

private struct RemoteFileMutationIntentFailure: Error {}

private actor RemoteFileMutationGate {
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

private actor BlockingDisconnectRemoteFileClient: SFTPRemoteFileClient {
    private var disconnectStarted = false
    private var disconnectWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var releaseRequested = false

    func waitUntilDisconnectStarted() async {
        if disconnectStarted { return }
        await withCheckedContinuation { continuation in
            disconnectWaiters.append(continuation)
        }
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

    func listDirectory(at path: String, maxEntries: Int?) async throws -> [RemoteFileEntry] { [] }

    func stat(at path: String) async throws -> RemoteFileEntry {
        makeEntry(path: path)
    }

    func lstat(at path: String) async throws -> RemoteFileEntry {
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
