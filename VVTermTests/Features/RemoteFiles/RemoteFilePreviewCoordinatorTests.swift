import Foundation
import Testing
@testable import VVTerm

// Test Context:
// These tests protect remote-file preview coordination and temporary preview
// lifecycle, including preview-load request ownership and edited text preview
// save ordering. Fakes avoid real SFTP and UI preview controllers; update only
// when preview workflow semantics or the application-layer owner for preview
// load/save requests intentionally changes.

@MainActor
struct RemoteFilePreviewCoordinatorTests {
    @Test
    func previewLoadRequestRejectsMismatchedTabServerWithoutCreatingWork() async {
        let server = makeServer()
        let tab = RemoteFileTab(serverId: UUID(), seedPath: "/tmp")
        let entry = makeEntry(name: "notes.txt", path: "/tmp/notes.txt", size: 5)
        let client = BlockingPreviewLoadClient(data: Data("hello".utf8))
        let store = makeStore(client: client)

        // Given the tab belongs to a different server than the preview request.
        let requestID = store.requestPreviewLoad(for: entry, in: tab, server: server)

        // Then the store rejects the request without creating preview-load work.
        #expect(requestID == nil)
        #expect(
            store.pendingPreviewLoadRequestIDs.isEmpty,
            "A mismatched tab/server preview request must not leave pending request state."
        )
        #expect(await client.readCount() == 0)
    }

    @Test
    func previewLoadRequestStaysTrackedUntilPreviewPayloadIsApplied() async throws {
        let server = makeServer()
        let tab = RemoteFileTab(serverId: server.id, seedPath: "/tmp")
        let entry = makeEntry(name: "notes.txt", path: "/tmp/notes.txt", size: 5)
        let client = BlockingPreviewLoadClient(data: Data("hello".utf8))
        let store = makeStore(client: client)

        // When preview load is sent from synchronous UI intent.
        let requestID = try #require(store.requestPreviewLoad(for: entry, in: tab, server: server))
        await client.waitUntilReadStarted()

        // Then the application store owns the preview-load task while remote read is blocked.
        #expect(store.pendingPreviewLoadRequestIDs == [requestID])
        #expect(store.isLoadingViewer(for: tab))
        #expect(await client.readCount() == 1)

        await client.releaseRead()
        await store.waitForPreviewLoadRequest(requestID)

        // And request bookkeeping clears only after payload application finishes.
        #expect(store.pendingPreviewLoadRequestIDs.isEmpty)
        #expect(!store.isLoadingViewer(for: tab))
        #expect(store.viewerPayload(for: tab)?.previewKind == .text)
        #expect(store.viewerPayload(for: tab)?.textPreview == "hello")
    }

    @Test
    func duplicatePreviewLoadRequestsForSameEntryCoalesceToOneRemoteRead() async throws {
        let server = makeServer()
        let tab = RemoteFileTab(serverId: server.id, seedPath: "/tmp")
        let entry = makeEntry(name: "notes.txt", path: "/tmp/notes.txt", size: 5)
        let client = BlockingPreviewLoadClient(data: Data("hello".utf8))
        let store = makeStore(client: client)

        // When the same preview-load intent is sent twice before the first read finishes.
        let firstRequestID = try #require(store.requestPreviewLoad(for: entry, in: tab, server: server))
        let secondRequestID = try #require(store.requestPreviewLoad(for: entry, in: tab, server: server))
        await client.waitUntilReadStarted()

        // Then both UI callbacks share one store-owned request and one remote read.
        #expect(firstRequestID == secondRequestID)
        #expect(store.pendingPreviewLoadRequestIDs == [firstRequestID])
        #expect(
            await client.readCount() == 1,
            "Duplicate same-entry preview-load intent should not start duplicate remote reads."
        )

        await client.releaseRead()
        await store.waitForPreviewLoadRequest(firstRequestID)
        #expect(store.pendingPreviewLoadRequestIDs.isEmpty)
    }

    @Test
    func clearViewerClearsPendingPreviewLoadRequest() async throws {
        let server = makeServer()
        let tab = RemoteFileTab(serverId: server.id, seedPath: "/tmp")
        let entry = makeEntry(name: "notes.txt", path: "/tmp/notes.txt", size: 5)
        let client = BlockingPreviewLoadClient(data: Data("hello".utf8))
        let store = makeStore(client: client)

        // Given preview-load work is running for the tab.
        let requestID = try #require(store.requestPreviewLoad(for: entry, in: tab, server: server))
        await client.waitUntilReadStarted()
        #expect(store.pendingPreviewLoadRequestIDs == [requestID])

        // When the real viewer cleanup path runs.
        store.clearViewer(for: tab)

        // Then cleanup owns cancellation/bookkeeping for pending preview-load work.
        #expect(
            store.pendingPreviewLoadRequestIDs.isEmpty,
            "Clearing the viewer must clear store-owned preview-load request bookkeeping."
        )
        #expect(store.selectedEntryPath(for: tab) == nil)
        #expect(store.viewerPayload(for: tab) == nil)
        #expect(store.viewerError(for: tab) == nil)
        #expect(!store.isLoadingViewer(for: tab))

        await expectCanceledPreviewLoadRemainsAwaitable(
            requestID,
            store: store,
            client: client
        )
        #expect(store.viewerPayload(for: tab) == nil)
    }

    @Test
    func focusClearsPendingPreviewLoadRequestForPreviousSelection() async throws {
        let server = makeServer()
        let tab = RemoteFileTab(serverId: server.id, seedPath: "/tmp")
        let firstEntry = makeEntry(name: "notes.txt", path: "/tmp/notes.txt", size: 5)
        let secondEntry = makeEntry(name: "next.txt", path: "/tmp/next.txt", size: 4)
        let client = BlockingPreviewLoadClient(data: Data("hello".utf8))
        let store = makeStore(client: client)

        // Given preview-load work is running for the previous selection.
        let requestID = try #require(store.requestPreviewLoad(for: firstEntry, in: tab, server: server))
        await client.waitUntilReadStarted()
        #expect(store.pendingPreviewLoadRequestIDs == [requestID])

        // When file focus moves to another entry through the real selection path.
        store.focus(secondEntry, in: tab)

        // Then the previous preview-load request is no longer owned as pending work.
        #expect(
            store.pendingPreviewLoadRequestIDs.isEmpty,
            "Selecting another file must clear pending preview-load request bookkeeping for the previous selection."
        )
        #expect(store.selectedEntryPath(for: tab) == secondEntry.path)
        #expect(store.viewerPayload(for: tab) == nil)
        #expect(store.viewerError(for: tab) == nil)
        #expect(!store.isLoadingViewer(for: tab))

        await expectCanceledPreviewLoadRemainsAwaitable(
            requestID,
            store: store,
            client: client
        )
        #expect(store.viewerPayload(for: tab) == nil)
        #expect(store.selectedEntryPath(for: tab) == secondEntry.path)
    }

    @Test
    func loadDirectoryClearsPendingPreviewLoadRequestAndPreventsStalePayload() async throws {
        let server = makeServer()
        let tab = RemoteFileTab(serverId: server.id, seedPath: "/tmp")
        let entry = makeEntry(name: "notes.txt", path: "/tmp/notes.txt", size: 5)
        let client = BlockingPreviewLoadClient(data: Data("hello".utf8))
        let store = makeStore(client: client)

        // Given preview-load work is running for the current directory selection.
        let requestID = try #require(store.requestPreviewLoad(for: entry, in: tab, server: server))
        await client.waitUntilReadStarted()
        #expect(store.pendingPreviewLoadRequestIDs == [requestID])

        // When directory navigation resets the viewer through the real load path.
        let loadTask = Task { @MainActor in
            await store.loadDirectory(path: "/var/log", in: tab, server: server)
        }
        await Task.yield()

        // Then the pending preview-load request is no longer visible for the tab.
        #expect(store.pendingPreviewLoadRequestIDs.isEmpty)
        #expect(store.selectedEntryPath(for: tab) == nil)
        #expect(store.viewerPayload(for: tab) == nil)
        #expect(store.viewerError(for: tab) == nil)
        #expect(!store.isLoadingViewer(for: tab))

        await expectCanceledPreviewLoadRemainsAwaitable(
            requestID,
            store: store,
            client: client
        )
        await loadTask.value
        #expect(store.currentPathValue(for: tab) == "/var/log")
        #expect(store.viewerPayload(for: tab) == nil)
    }

    @Test
    func removeRuntimeStateClearsPendingPreviewLoadRequestAndPreventsStalePayload() async throws {
        let server = makeServer()
        let tab = RemoteFileTab(serverId: server.id, seedPath: "/tmp")
        let entry = makeEntry(name: "notes.txt", path: "/tmp/notes.txt", size: 5)
        let client = BlockingPreviewLoadClient(data: Data("hello".utf8))
        let store = makeStore(client: client)

        // Given preview-load work is running for a tab runtime.
        let requestID = try #require(store.requestPreviewLoad(for: entry, in: tab, server: server))
        await client.waitUntilReadStarted()
        #expect(store.pendingPreviewLoadRequestIDs == [requestID])

        // When the tab runtime state is removed.
        store.removeRuntimeState(for: tab.id)

        // Then preview-load work is detached from visible state immediately.
        #expect(store.pendingPreviewLoadRequestIDs.isEmpty)
        #expect(store.states[tab.id] == nil)

        await expectCanceledPreviewLoadRemainsAwaitable(
            requestID,
            store: store,
            client: client
        )
        #expect(store.states[tab.id] == nil)
    }

    @Test
    func disconnectClearsPendingPreviewLoadRequestAndPreventsStalePayload() async throws {
        let server = makeServer()
        let tab = RemoteFileTab(serverId: server.id, seedPath: "/tmp")
        let entry = makeEntry(name: "notes.txt", path: "/tmp/notes.txt", size: 5)
        let client = BlockingPreviewLoadClient(data: Data("hello".utf8))
        let store = makeStore(client: client)

        // Given preview-load work is running for a server that will disconnect.
        let requestID = try #require(store.requestPreviewLoad(for: entry, in: tab, server: server))
        await client.waitUntilReadStarted()
        #expect(store.pendingPreviewLoadRequestIDs == [requestID])

        // When the server disconnect path removes affected runtime state.
        let disconnectTask = store.disconnect(serverId: server.id)

        // Then the preview load is no longer visible as pending work.
        #expect(store.pendingPreviewLoadRequestIDs.isEmpty)
        #expect(store.states[tab.id] == nil)

        await expectCanceledPreviewLoadRemainsAwaitable(
            requestID,
            store: store,
            client: client
        )
        await disconnectTask.value
        #expect(store.states[tab.id] == nil)
    }

    @Test
    func disconnectWaitsForCanceledPreviewLoadBeforeRemoteDisconnect() async throws {
        let server = makeServer()
        let tab = RemoteFileTab(serverId: server.id, seedPath: "/tmp")
        let entry = makeEntry(name: "notes.txt", path: "/tmp/notes.txt", size: 5)
        let client = BlockingPreviewLoadClient(data: Data("hello".utf8), blocksDisconnect: true)
        let store = RemoteFileBrowserStore(
            persistedStateStore: RemoteFileBrowserPersistedStateStore(userDefaults: makeDefaults()),
            remoteFileServiceAccess: NonSerializingRemoteFileServiceAccess(client: client),
            serverProvider: { _ in nil }
        )
        let waitProbe = PreviewLoadWaitProbe()

        _ = try await store.withRemoteFileService(for: server) { service in
            try await service.resolveHomeDirectory()
        }

        // Given preview loading is blocked inside remote read IO.
        let requestID = try #require(store.requestPreviewLoad(for: entry, in: tab, server: server))
        await client.waitUntilReadStarted()

        // When the same server disconnects.
        let disconnectTask = store.disconnect(serverId: server.id)
        let disconnectWaitTask = Task { @MainActor in
            await disconnectTask.value
            await waitProbe.markFinished()
        }
        try await Task.sleep(for: .milliseconds(20))

        // Then service disconnect waits for preview cleanup to exit.
        #expect(store.pendingPreviewLoadRequestIDs.isEmpty)
        #expect(
            await !client.hasStartedDisconnect(),
            "RemoteFiles disconnect should wait for canceled preview read to exit before disconnecting the SFTP service."
        )
        #expect(
            await !waitProbe.didFinish(),
            "RemoteFiles disconnect task should not complete while canceled preview read is still blocked."
        )

        await client.releaseRead()
        await client.waitUntilDisconnectStarted()
        await client.releaseDisconnect()
        await disconnectWaitTask.value

        #expect(await waitProbe.didFinish())
        #expect(store.states[tab.id] == nil)
        #expect(!store.pendingPreviewLoadRequestIDs.contains(requestID))
    }

    @Test
    func clearViewerRemovesPreviewArtifactAndResetsState() throws {
        let rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let temporaryStorage = RemoteFileTemporaryStorage(rootDirectory: rootDirectory)
        let store = RemoteFileBrowserStore(
            persistedStateStore: RemoteFileBrowserPersistedStateStore(userDefaults: makeDefaults()),
            temporaryStorage: temporaryStorage,
            serverProvider: { _ in nil }
        )
        let tab = makeTab()
        let entry = makeEntry(name: "preview.txt", path: "/tmp/preview.txt")
        let previewURL = try temporaryStorage.makePreviewFileURL(for: entry)
        try Data("preview".utf8).write(to: previewURL)

        store.updateState(for: tab) { state in
            state.selectedEntryPath = entry.path
            state.viewerPayload = RemoteFileViewerPayload(
                previewKind: .text,
                entry: entry,
                textPreview: "preview",
                previewFileURL: previewURL,
                isTruncated: false,
                unavailableMessage: nil,
                requiresExplicitDownload: false,
                previewByteCount: 7
            )
            state.viewerError = .failed("stale")
            state.isLoadingViewer = true
        }

        store.clearViewer(for: tab)

        #expect(!FileManager.default.fileExists(atPath: previewURL.path))
        #expect(store.selectedEntryPath(for: tab) == nil)
        #expect(store.viewerPayload(for: tab) == nil)
        #expect(store.viewerError(for: tab) == nil)
        #expect(!store.isLoadingViewer(for: tab))
    }

    @Test
    func textPreviewSaveRequestTracksUploadAndRunsSuccessAfterStoreSave() async throws {
        let server = makeServer()
        let tab = RemoteFileTab(serverId: server.id, seedPath: "/tmp")
        let entry = makeEntry(name: "notes.txt", path: "/tmp/notes.txt", permissions: 0o600)
        let client = BlockingPreviewSaveClient(updatedEntry: makeEntry(
            name: "notes.txt",
            path: "/tmp/notes.txt",
            size: 12,
            permissions: 0o600
        ))
        let store = RemoteFileBrowserStore(
            persistedStateStore: RemoteFileBrowserPersistedStateStore(userDefaults: makeDefaults()),
            remoteFileServiceAccess: SSHSFTPAdapter(
                credentialsProvider: { server in makeCredentials(serverId: server.id) },
                ownedClientFactory: { client }
            ),
            serverProvider: { _ in nil }
        )
        var events: [String] = []
        store.updateState(for: tab) { state in
            state.entries = [entry]
            state.selectedEntryPath = entry.path
            state.viewerPayload = RemoteFileViewerPayload(
                previewKind: .text,
                entry: entry,
                textPreview: "old text",
                previewFileURL: nil,
                isTruncated: false,
                unavailableMessage: nil,
                requiresExplicitDownload: false,
                previewByteCount: 8
            )
        }

        // Given edited preview text save is sent from synchronous UI intent.
        let requestID = store.requestTextPreviewSave(
            "updated text",
            for: entry,
            in: tab,
            server: server,
            onSaved: {
                events.append("saved")
            },
            onFailure: { error in
                events.append("failed-\(type(of: error))")
            }
        )
        await client.waitUntilUploadStarted()

        // Then the application store owns the save task until the upload and
        // state update finish.
        #expect(store.pendingMutationRequestIDs.contains(requestID))
        #expect(events.isEmpty)

        await client.releaseUpload()
        await store.waitForMutationRequest(requestID)

        #expect(!store.pendingMutationRequestIDs.contains(requestID))
        #expect(events == ["saved"])
        #expect(await client.uploadedText() == "updated text")
        #expect(store.viewerPayload(for: tab)?.textPreview == "updated text")
        #expect(store.viewerPayload(for: tab)?.previewByteCount == UInt64("updated text".utf8.count))
        #expect(store.entries(for: tab).first?.size == 12)
    }

    private func makeEntry(
        name: String,
        path: String,
        size: UInt64? = nil,
        permissions: UInt32? = nil
    ) -> RemoteFileEntry {
        RemoteFileEntry(
            name: name,
            path: path,
            type: .file,
            size: size,
            modifiedAt: nil,
            permissions: permissions,
            symlinkTarget: nil
        )
    }

    private func makeTab() -> RemoteFileTab {
        RemoteFileTab(serverId: UUID(), seedPath: "/tmp")
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "RemoteFilePreviewCoordinatorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func makeServer() -> Server {
        Server(
            workspaceId: UUID(),
            name: "Preview Save",
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

    private func makeStore(client: SFTPRemoteFileClient) -> RemoteFileBrowserStore {
        RemoteFileBrowserStore(
            persistedStateStore: RemoteFileBrowserPersistedStateStore(userDefaults: makeDefaults()),
            remoteFileServiceAccess: SSHSFTPAdapter(
                credentialsProvider: { server in makeCredentials(serverId: server.id) },
                ownedClientFactory: { client }
            ),
            serverProvider: { _ in nil }
        )
    }

    private func expectCanceledPreviewLoadRemainsAwaitable(
        _ requestID: UUID,
        store: RemoteFileBrowserStore,
        client: BlockingPreviewLoadClient
    ) async {
        let waitProbe = PreviewLoadWaitProbe()
        let waiter = Task { @MainActor in
            await store.waitForPreviewLoadRequest(requestID)
            await waitProbe.markFinished()
        }
        await Task.yield()
        #expect(
            await !waitProbe.didFinish(),
            "Canceled preview-load work should stay awaitable until the underlying task exits."
        )

        await client.releaseRead()
        await waiter.value
        #expect(await waitProbe.didFinish())
        #expect(!store.pendingPreviewLoadRequestIDs.contains(requestID))
    }
}

private actor BlockingPreviewLoadClient: SFTPRemoteFileClient {
    private let data: Data
    private let blocksDisconnect: Bool
    private var reads = 0
    private var readStarted = false
    private var readStartedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var releaseRequested = false
    private var disconnectStarted = false
    private var disconnectWaiters: [CheckedContinuation<Void, Never>] = []
    private var disconnectReleaseContinuation: CheckedContinuation<Void, Never>?
    private var disconnectReleaseRequested = false

    init(data: Data, blocksDisconnect: Bool = false) {
        self.data = data
        self.blocksDisconnect = blocksDisconnect
    }

    func waitUntilReadStarted() async {
        if readStarted { return }
        await withCheckedContinuation { continuation in
            readStartedWaiters.append(continuation)
        }
    }

    func releaseRead() {
        if let releaseContinuation {
            releaseContinuation.resume()
            self.releaseContinuation = nil
        } else {
            releaseRequested = true
        }
    }

    func readCount() -> Int {
        reads
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

    func listDirectory(at path: String, maxEntries: Int?) async throws -> [SSHFileTransferEntry] { [] }

    func stat(at path: String) async throws -> SSHFileTransferEntry {
        SSHFileTransferEntry(
            name: URL(fileURLWithPath: path).lastPathComponent,
            path: path,
            type: .file,
            size: UInt64(data.count),
            modifiedAt: nil,
            permissions: nil,
            symlinkTarget: nil
        )
    }

    func lstat(at path: String) async throws -> SSHFileTransferEntry {
        try await stat(at: path)
    }

    func readFile(at path: String, maxBytes: Int) async throws -> Data {
        reads += 1
        readStarted = true
        for waiter in readStartedWaiters {
            waiter.resume()
        }
        readStartedWaiters.removeAll()
        guard !releaseRequested else { return data }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
        return data
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

    func resolveHomeDirectory() async throws -> String { "/home/test" }

    func fileSystemStatus(at path: String) async throws -> SSHFileTransferFilesystemStatus {
        SSHFileTransferFilesystemStatus(
            blockSize: 1,
            totalBlocks: 0,
            freeBlocks: 0,
            availableBlocks: 0
        )
    }
}

private actor PreviewLoadWaitProbe {
    private var finished = false

    func markFinished() {
        finished = true
    }

    func didFinish() -> Bool {
        finished
    }
}

private actor BlockingPreviewSaveClient: SFTPRemoteFileClient {
    private let updatedEntry: RemoteFileEntry
    private var uploadedData = Data()
    private var uploadStarted = false
    private var uploadStartedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var releaseRequested = false

    init(updatedEntry: RemoteFileEntry) {
        self.updatedEntry = updatedEntry
    }

    func waitUntilUploadStarted() async {
        if uploadStarted { return }
        await withCheckedContinuation { continuation in
            uploadStartedWaiters.append(continuation)
        }
    }

    func releaseUpload() {
        if let releaseContinuation {
            releaseContinuation.resume()
            self.releaseContinuation = nil
        } else {
            releaseRequested = true
        }
    }

    func uploadedText() -> String? {
        String(data: uploadedData, encoding: .utf8)
    }

    func connectForRemoteFileLease(to server: Server, credentials: ServerCredentials) async throws {}

    func disconnect() async {}

    func execute(_ command: String, timeout: Duration?) async throws -> String { "" }

    func remoteEnvironment(forceRefresh: Bool) async -> RemoteEnvironment { .fallbackPOSIX }

    func remoteTerminalType(forceRefresh: Bool) async -> RemoteTerminalType { .xterm256Color }

    func listDirectory(at path: String, maxEntries: Int?) async throws -> [SSHFileTransferEntry] { [] }

    func stat(at path: String) async throws -> SSHFileTransferEntry {
        SSHFileTransferEntry(remoteFileEntry: updatedEntry)
    }

    func lstat(at path: String) async throws -> SSHFileTransferEntry {
        SSHFileTransferEntry(remoteFileEntry: updatedEntry)
    }

    func readFile(at path: String, maxBytes: Int) async throws -> Data { Data() }

    func downloadFile(at path: String, to localURL: URL) async throws {}

    func upload(
        _ data: Data,
        to remotePath: String,
        permissions: Int32,
        strategy: SSHUploadStrategy
    ) async throws {
        uploadedData = data
        uploadStarted = true
        for waiter in uploadStartedWaiters {
            waiter.resume()
        }
        uploadStartedWaiters.removeAll()
        guard !releaseRequested else { return }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

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
}
