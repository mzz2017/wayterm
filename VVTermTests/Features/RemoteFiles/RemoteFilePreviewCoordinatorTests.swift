import Foundation
import Testing
@testable import VVTerm

// Test Context:
// These tests protect remote-file preview coordination and temporary preview
// lifecycle, including edited text preview save ordering. Fakes avoid real
// SFTP and UI preview controllers; update only when preview workflow semantics
// or the application-layer owner for preview-save requests intentionally
// changes.

@MainActor
struct RemoteFilePreviewCoordinatorTests {
    @Test
    func clearViewerRemovesPreviewArtifactAndResetsState() throws {
        let rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let temporaryStorage = RemoteFileTemporaryStorage(rootDirectory: rootDirectory)
        let store = RemoteFileBrowserStore(
            defaults: makeDefaults(),
            temporaryStorage: temporaryStorage
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
            defaults: makeDefaults(),
            remoteFileServiceAdapter: SSHSFTPAdapter(
                credentialsProvider: { server in makeCredentials(serverId: server.id) },
                ownedClientFactory: { client }
            )
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

    func listDirectory(at path: String, maxEntries: Int?) async throws -> [RemoteFileEntry] { [] }

    func stat(at path: String) async throws -> RemoteFileEntry { updatedEntry }

    func lstat(at path: String) async throws -> RemoteFileEntry { updatedEntry }

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

    func fileSystemStatus(at path: String) async throws -> RemoteFileFilesystemStatus {
        RemoteFileFilesystemStatus(
            blockSize: 1,
            totalBlocks: 0,
            freeBlocks: 0,
            availableBlocks: 0
        )
    }
}
