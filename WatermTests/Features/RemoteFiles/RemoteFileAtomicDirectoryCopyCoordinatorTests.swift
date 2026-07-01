import Foundation
import Testing
@testable import Waterm

// Test Context:
// These tests protect atomic remote-directory copy publication and cleanup.
// Fakes avoid real SFTP/network I/O; update only when the staging directory,
// publish conflict, or awaitable cleanup ownership intentionally changes.

@MainActor
struct RemoteFileAtomicDirectoryCopyCoordinatorTests {
    @Test
    func publishFailureAwaitsStagingCleanup() async throws {
        let coordinator = RemoteFileAtomicDirectoryCopyCoordinator()
        let sourceEntry = makeEntry(name: "folder", path: "/source/folder", type: .directory)
        let sourceService = DirectoryCopyRecordingRemoteFileService(directoryContents: [
            "/source/folder": []
        ])
        let destinationService = DirectoryCopyRecordingRemoteFileService(
            directoryContents: [:],
            existingEntries: [
                "/destination/folder": makeEntry(name: "folder", path: "/destination/folder", type: .directory)
            ]
        )

        // Given an atomic directory copy has staged the destination tree, but
        // another client already owns the final destination path.
        do {
            try await coordinator.copyDirectory(
                sourceEntry,
                effectiveEntry: sourceEntry,
                to: "/destination",
                sourceService: sourceService,
                destinationService: destinationService,
                progressTracker: nil,
                copyChild: { _, _ in }
            )
            Issue.record("Expected atomic directory publish to fail when the destination exists")
        } catch RemoteFilePublishError.destinationExists {
            // Expected publish failure.
        } catch {
            Issue.record("Expected destinationExists, got \(error)")
        }

        // Then the coordinator waits for staging cleanup before returning the
        // publish failure, so callers never observe completion while temporary
        // remote directories are still being removed.
        let operations = destinationService.operations
        let stagingPath = try #require(operations.compactMap { operation -> String? in
            guard case .createDirectory(let path) = operation else { return nil }
            return path
        }.first)
        #expect(stagingPath.hasPrefix("/destination/.folder.waterm-copy-"))
        #expect(operations.contains(.deleteDirectory(stagingPath)))
        #expect(!operations.contains(.renameItem(source: stagingPath, destination: "/destination/folder")))
    }

    private func makeEntry(
        name: String,
        path: String,
        type: RemoteFileType,
        permissions: UInt32? = nil
    ) -> RemoteFileEntry {
        RemoteFileEntry(
            name: name,
            path: path,
            type: type,
            size: nil,
            modifiedAt: nil,
            permissions: permissions,
            symlinkTarget: nil
        )
    }
}

private final class DirectoryCopyRecordingRemoteFileService: RemoteFileService, @unchecked Sendable {
    enum Operation: Equatable, Sendable {
        case createDirectory(String)
        case renameItem(source: String, destination: String)
        case deleteFile(String)
        case deleteDirectory(String)
    }

    private let directoryContents: [String: [RemoteFileEntry]]
    private let lock = NSLock()
    private var existingEntries: [String: RemoteFileEntry]
    private var operationStorage: [Operation] = []

    init(
        directoryContents: [String: [RemoteFileEntry]],
        existingEntries: [String: RemoteFileEntry] = [:]
    ) {
        self.directoryContents = directoryContents
        self.existingEntries = existingEntries
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
        let normalizedPath = RemoteFilePath.normalize(path)
        guard let entry = lock.withLock({ existingEntries[normalizedPath] }) else {
            throw RemoteFileBrowserError.pathNotFound
        }
        return entry
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

    func createDirectory(at path: String, permissions: Int32) async throws {
        record(.createDirectory(RemoteFilePath.normalize(path)))
    }

    func renameItem(at sourcePath: String, to destinationPath: String) async throws {
        record(.renameItem(
            source: RemoteFilePath.normalize(sourcePath),
            destination: RemoteFilePath.normalize(destinationPath)
        ))
    }

    func renameItemIfDestinationMissing(at sourcePath: String, to destinationPath: String) async throws {
        let normalizedDestination = RemoteFilePath.normalize(destinationPath)
        do {
            _ = try await lstat(at: normalizedDestination)
            throw RemoteFilePublishError.destinationExists(normalizedDestination)
        } catch let error as RemoteFileBrowserError where error == .pathNotFound {
            try await renameItem(at: sourcePath, to: normalizedDestination)
        }
    }

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
        lock.withLock {
            operationStorage.append(operation)
        }
    }
}
