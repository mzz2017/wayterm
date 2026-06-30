import Foundation
import Testing
@testable import VVTerm

// Test Context:
// These tests protect remote-file transfer coordination and progress/error flow.
// Fakes avoid real network and filesystem transfer side effects; update only when
// transfer workflow semantics intentionally change.

@MainActor
struct RemoteFileTransferCoordinatorTests {
    @Test
    func conflictResolutionComputedStateRemainsNonisolatedForTransferPlanning() throws {
        let root = try sourceRoot()
        let conflictSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/RemoteFiles/Domain/RemoteFileConflictPolicy.swift")
        )

        // Given upload planning runs off the MainActor while resolving names.
        #expect(
            conflictSource.contains("nonisolated var hasConflict"),
            "RemoteFileConflictResolution is a Sendable domain value; conflict checks should not inherit MainActor isolation."
        )
    }

    @Test
    func deleteDirectoryRecursivelyRemovesNestedContentsBeforeParent() async throws {
        let store = RemoteFileBrowserStore(persistedStateStore: RemoteFileBrowserPersistedStateStore(userDefaults: makeDefaults()), serverProvider: { _ in nil })
        let service = RecordingRemoteFileService(
            directoryContents: [
                "/root/.vivyterm": [
                    makeEntry(name: "cache", path: "/root/.vivyterm/cache", type: .directory),
                    makeEntry(name: "config.json", path: "/root/.vivyterm/config.json", type: .file),
                    makeEntry(name: "current", path: "/root/.vivyterm/current", type: .symlink)
                ],
                "/root/.vivyterm/cache": [
                    makeEntry(name: "index.db", path: "/root/.vivyterm/cache/index.db", type: .file)
                ]
            ]
        )

        try await store.deleteDirectoryRecursively(at: "/root/.vivyterm", using: service)

        #expect(service.operations == [
            .deleteFile("/root/.vivyterm/cache/index.db"),
            .deleteDirectory("/root/.vivyterm/cache"),
            .deleteFile("/root/.vivyterm/config.json"),
            .deleteFile("/root/.vivyterm/current"),
            .deleteDirectory("/root/.vivyterm")
        ])
    }

    @Test
    func downloadDirectoryCancellationStopsBeforeNextChild() async throws {
        let store = RemoteFileBrowserStore(
            persistedStateStore: RemoteFileBrowserPersistedStateStore(userDefaults: makeDefaults()),
            serverProvider: { _ in nil }
        )
        let downloadBlocker = RemoteFileDownloadBlocker(blockedPath: "/remote/first.txt")
        let service = RecordingRemoteFileService(
            directoryContents: [
                "/remote": [
                    makeEntry(name: "first.txt", path: "/remote/first.txt", type: .file),
                    makeEntry(name: "second.txt", path: "/remote/second.txt", type: .file)
                ]
            ],
            downloadBlocker: downloadBlocker
        )
        let destinationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteFileTransferCoordinatorTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: destinationURL) }

        // Given recursive download is blocked inside the first child transfer.
        let task = Task {
            try await store.downloadItem(
                makeEntry(name: "remote", path: "/remote", type: .directory),
                to: destinationURL,
                using: service
            )
        }
        await downloadBlocker.waitUntilStarted()

        // When the transfer task is canceled before the first child returns.
        task.cancel()
        await downloadBlocker.release()

        // Then cancellation is observed before the next sibling transfer.
        do {
            try await task.value
            Issue.record("Expected recursive directory download to stop after cancellation")
        } catch is CancellationError {
            #expect(service.operations == [
                .downloadFile("/remote/first.txt")
            ])
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }
    }

    private func makeEntry(name: String, path: String, type: RemoteFileType = .file) -> RemoteFileEntry {
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

    private func makeDefaults() -> UserDefaults {
        let suiteName = "RemoteFileTransferCoordinatorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func source(at url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    private func sourceRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.lastPathComponent != "VVTermTests" {
            let next = url.deletingLastPathComponent()
            if next.path == url.path {
                throw SourceRootError.notFound
            }
            url = next
        }
        return url.deletingLastPathComponent()
    }

    private enum SourceRootError: Error {
        case notFound
    }
}

private final class RecordingRemoteFileService: RemoteFileService, @unchecked Sendable {
    enum Operation: Equatable, Sendable {
        case downloadFile(String)
        case deleteFile(String)
        case deleteDirectory(String)
    }

    let directoryContents: [String: [RemoteFileEntry]]
    let downloadBlocker: RemoteFileDownloadBlocker?
    private let lock = NSLock()
    private var operationStorage: [Operation] = []

    var operations: [Operation] {
        lock.lock()
        defer { lock.unlock() }
        return operationStorage
    }

    init(
        directoryContents: [String: [RemoteFileEntry]],
        downloadBlocker: RemoteFileDownloadBlocker? = nil
    ) {
        self.directoryContents = directoryContents
        self.downloadBlocker = downloadBlocker
    }

    func listDirectory(at path: String, maxEntries: Int?) async throws -> [RemoteFileEntry] {
        directoryContents[RemoteFilePath.normalize(path)] ?? []
    }

    func stat(at path: String) async throws -> RemoteFileEntry {
        throw RemoteFileBrowserError.failed("Unused in tests")
    }

    func lstat(at path: String) async throws -> RemoteFileEntry {
        throw RemoteFileBrowserError.failed("Unused in tests")
    }

    func readFile(at path: String, maxBytes: Int) async throws -> Data {
        Data()
    }

    func downloadFile(at path: String, to localURL: URL) async throws {
        let normalizedPath = RemoteFilePath.normalize(path)
        record(.downloadFile(normalizedPath))
        await downloadBlocker?.waitIfNeeded(path: normalizedPath)
    }

    func upload(
        _ data: Data,
        to remotePath: String,
        permissions: Int32,
        strategy: SSHUploadStrategy
    ) async throws {}

    func createDirectory(at path: String, permissions: Int32) async throws {}

    func renameItem(at sourcePath: String, to destinationPath: String) async throws {}

    func deleteFile(at path: String) async throws {
        record(.deleteFile(RemoteFilePath.normalize(path)))
    }

    func deleteDirectory(at path: String) async throws {
        record(.deleteDirectory(RemoteFilePath.normalize(path)))
    }

    func setPermissions(at path: String, permissions: UInt32) async throws {}

    func resolveHomeDirectory() async throws -> String {
        "/"
    }

    func fileSystemStatus(at path: String) async throws -> RemoteFileFilesystemStatus {
        throw RemoteFileBrowserError.failed("Unused in tests")
    }

    private func record(_ operation: Operation) {
        lock.lock()
        operationStorage.append(operation)
        lock.unlock()
    }
}

private actor RemoteFileDownloadBlocker {
    let blockedPath: String
    private var started = false
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    init(blockedPath: String) {
        self.blockedPath = blockedPath
    }

    func waitIfNeeded(path: String) async {
        guard path == blockedPath else { return }
        started = true
        startedWaiters.forEach { $0.resume() }
        startedWaiters.removeAll()

        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { continuation in
            startedWaiters.append(continuation)
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}
