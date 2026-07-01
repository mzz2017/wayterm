import Foundation
import Testing
@testable import Waterm

// Test Context:
// These tests protect atomic remote-file cleanup ownership. Fakes avoid real
// SFTP/network I/O; update only when temporary file/directory cleanup ordering
// or awaitable cleanup ownership intentionally changes.

@MainActor
struct RemoteFileAtomicCleanupCoordinatorTests {
    @Test
    func temporaryFileCleanupWaitsForDeleteCompletion() async {
        let deleteGate = AtomicCleanupGate()
        let service = AtomicCleanupRecordingRemoteFileService(
            directoryContents: [:],
            onDeleteFile: { _ in
                await deleteGate.waitForRelease()
            }
        )
        let coordinator = RemoteFileAtomicCleanupCoordinator()
        let returnProbe = AtomicCleanupReturnProbe()

        // Given atomic cleanup starts deleting a temporary remote file.
        let cleanupTask = Task {
            await coordinator.removeTemporaryFile("/remote/.upload.tmp", using: service)
            await returnProbe.markReturned()
        }
        await deleteGate.waitForOperationStart()

        // Then cleanup has not returned before remote deletion exits.
        #expect(
            !(await returnProbe.didReturn()),
            "Temporary-file cleanup must stay pending while remote delete is still running."
        )
        #expect(service.operations == [.deleteFile("/remote/.upload.tmp")])

        await deleteGate.release()
        await cleanupTask.value

        #expect(await returnProbe.didReturn())
        #expect(
            service.operations == [.deleteFile("/remote/.upload.tmp")],
            "Temporary-file cleanup should wait for the delete operation it owns."
        )
    }

    @Test
    func temporaryDirectoryCleanupDeletesChildrenBeforeDirectory() async {
        let service = AtomicCleanupRecordingRemoteFileService(
            directoryContents: [
                "/remote/.copy.tmp": [
                    makeEntry(name: "nested", path: "/remote/.copy.tmp/nested", type: .directory),
                    makeEntry(name: "file.txt", path: "/remote/.copy.tmp/file.txt", type: .file)
                ],
                "/remote/.copy.tmp/nested": [
                    makeEntry(name: "child.txt", path: "/remote/.copy.tmp/nested/child.txt", type: .file)
                ]
            ]
        )
        let coordinator = RemoteFileAtomicCleanupCoordinator()

        // Given atomic cleanup owns a staged remote directory tree.
        await coordinator.removeTemporaryDirectory("/remote/.copy.tmp", using: service)

        // Then it removes child files/directories before deleting the staged
        // directory itself.
        #expect(service.operations == [
            .deleteFile("/remote/.copy.tmp/nested/child.txt"),
            .deleteDirectory("/remote/.copy.tmp/nested"),
            .deleteFile("/remote/.copy.tmp/file.txt"),
            .deleteDirectory("/remote/.copy.tmp")
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
}

private actor AtomicCleanupReturnProbe {
    private var returned = false

    func markReturned() {
        returned = true
    }

    func didReturn() -> Bool {
        returned
    }
}

private actor AtomicCleanupGate {
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var hasStarted = false
    private var isReleased = false

    func waitForOperationStart() async {
        guard !hasStarted else { return }
        await withCheckedContinuation { continuation in
            startContinuation = continuation
        }
    }

    func waitForRelease() async {
        guard !hasStarted else {
            await waitUntilReleased()
            return
        }

        hasStarted = true
        startContinuation?.resume()
        startContinuation = nil
        await waitUntilReleased()
    }

    func release() {
        isReleased = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    private func waitUntilReleased() async {
        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }
}

private final class AtomicCleanupRecordingRemoteFileService: RemoteFileService, @unchecked Sendable {
    enum Operation: Equatable, Sendable {
        case deleteFile(String)
        case deleteDirectory(String)
    }

    private let directoryContents: [String: [RemoteFileEntry]]
    private let onDeleteFile: @Sendable (String) async -> Void
    private let lock = NSLock()
    private var operationStorage: [Operation] = []

    init(
        directoryContents: [String: [RemoteFileEntry]],
        onDeleteFile: @escaping @Sendable (String) async -> Void = { _ in }
    ) {
        self.directoryContents = directoryContents
        self.onDeleteFile = onDeleteFile
    }

    var operations: [Operation] {
        lock.withLock { operationStorage }
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

    func downloadFile(at path: String, to localURL: URL) async throws {}

    func upload(
        _ data: Data,
        to remotePath: String,
        permissions: Int32,
        strategy: SSHUploadStrategy
    ) async throws {}

    func createDirectory(at path: String, permissions: Int32) async throws {}

    func renameItem(at sourcePath: String, to destinationPath: String) async throws {}

    func renameItemIfDestinationMissing(at sourcePath: String, to destinationPath: String) async throws {}

    func deleteFile(at path: String) async throws {
        let normalizedPath = RemoteFilePath.normalize(path)
        record(.deleteFile(normalizedPath))
        await onDeleteFile(normalizedPath)
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
        lock.withLock {
            operationStorage.append(operation)
        }
    }
}
