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
    func deletionCoordinatorRemovesNestedContentsBeforeParent() async throws {
        let coordinator = RemoteFileDeletionCoordinator()
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

        // When a directory tree is deleted through the dedicated deletion owner.
        try await coordinator.deleteDirectoryRecursively(at: "/root/.vivyterm", using: service)

        // Then child files and directories are removed before the parent
        // directory, so partially deleted remote trees are not left with
        // undeleted descendants.
        #expect(service.operations == [
            .deleteFile("/root/.vivyterm/cache/index.db"),
            .deleteDirectory("/root/.vivyterm/cache"),
            .deleteFile("/root/.vivyterm/config.json"),
            .deleteFile("/root/.vivyterm/current"),
            .deleteDirectory("/root/.vivyterm")
        ])
    }

    @Test
    func deleteDirectoryCancellationStopsAfterDirectoryListingBeforeParentDelete() async throws {
        let store = RemoteFileBrowserStore(
            persistedStateStore: RemoteFileBrowserPersistedStateStore(userDefaults: makeDefaults()),
            serverProvider: { _ in nil }
        )
        let listBlocker = RemoteFileListBlocker(blockedPath: "/remote/empty")
        let service = RecordingRemoteFileService(
            directoryContents: ["/remote/empty": []],
            listBlocker: listBlocker
        )

        // Given recursive delete is blocked while listing an empty directory.
        let task = Task {
            try await store.deleteDirectoryRecursively(at: "/remote/empty", using: service)
        }
        await listBlocker.waitUntilStarted()

        // When cancellation arrives after the directory listing has started
        // but before the parent directory delete is allowed to run.
        task.cancel()
        await listBlocker.release()

        // Then cancellation is observed at the phase boundary before the
        // destructive parent delete operation.
        let result = await task.result
        #expect(service.operations.isEmpty)
        switch result {
        case .success:
            Issue.record("Expected recursive directory delete to stop after cancellation")
        case .failure(is CancellationError):
            break
        case .failure(let error):
            Issue.record("Expected CancellationError, got \(error)")
        }
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

    @Test
    func downloadDirectoryCancellationDoesNotExposePartialDestinationTree() async throws {
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
            downloadBlocker: downloadBlocker,
            downloadData: Data("partial-child".utf8)
        )
        let parentURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteFileTransferCoordinatorTests-\(UUID().uuidString)", isDirectory: true)
        let destinationURL = parentURL.appendingPathComponent("remote", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: parentURL) }

        // Given a recursive directory download is writing into the first child.
        let task = Task {
            try await store.downloadItem(
                makeEntry(name: "remote", path: "/remote", type: .directory),
                to: destinationURL,
                using: service
            )
        }
        await downloadBlocker.waitUntilStarted()

        // When cancellation arrives before the full directory tree completes.
        task.cancel()
        await downloadBlocker.release()

        // Then no partial user-visible destination tree is left behind.
        do {
            try await task.value
            Issue.record("Expected recursive directory download to stop after cancellation")
        } catch is CancellationError {
            #expect(
                !FileManager.default.fileExists(atPath: destinationURL.path),
                "Canceled directory downloads must not expose a partial final destination tree."
            )
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }
    }

    @Test
    func copyFileCancellationStopsAfterSourceDownloadBeforeDestinationUpload() async throws {
        let store = RemoteFileBrowserStore(
            persistedStateStore: RemoteFileBrowserPersistedStateStore(userDefaults: makeDefaults()),
            serverProvider: { _ in nil }
        )
        let downloadBlocker = RemoteFileDownloadBlocker(blockedPath: "/source/file.txt")
        let sourceService = RecordingRemoteFileService(
            directoryContents: [:],
            downloadBlocker: downloadBlocker,
            downloadData: Data("payload".utf8)
        )
        let destinationService = RecordingRemoteFileService(directoryContents: [:])

        // Given cross-server copy is blocked in the source download phase.
        let task = Task {
            try await store.copyRemoteEntry(
                makeEntry(name: "file.txt", path: "/source/file.txt", type: .file),
                to: "/destination",
                sourceService: sourceService,
                destinationService: destinationService,
                progressTracker: nil
            )
        }
        await downloadBlocker.waitUntilStarted()

        // When cancellation arrives after the source download has started but
        // before destination upload is allowed to mutate the target server.
        task.cancel()
        await downloadBlocker.release()

        // Then the copied payload is not uploaded to the destination server.
        let result = await task.result
        #expect(sourceService.operations == [
            .downloadFile("/source/file.txt")
        ])
        #expect(destinationService.operations.isEmpty)
        switch result {
        case .success:
            Issue.record("Expected cross-server copy to stop after cancellation")
        case .failure(is CancellationError):
            break
        case .failure(let error):
            Issue.record("Expected CancellationError, got \(error)")
        }
    }

    @Test
    func copyFileUploadsDestinationAtomically() async throws {
        let store = RemoteFileBrowserStore(
            persistedStateStore: RemoteFileBrowserPersistedStateStore(userDefaults: makeDefaults()),
            serverProvider: { _ in nil }
        )
        let sourceService = RecordingRemoteFileService(
            directoryContents: [:],
            downloadData: Data("copied payload".utf8)
        )
        let destinationService = RecordingRemoteFileService(directoryContents: [:])

        // Given a remote-to-remote copy transfers a file through local temporary
        // storage before writing the destination server.
        try await store.copyRemoteEntry(
            makeEntry(name: "file.txt", path: "/source/file.txt", type: .file),
            to: "/destination",
            sourceService: sourceService,
            destinationService: destinationService,
            progressTracker: nil
        )

        // Then the destination server never sees partial bytes at the final
        // path: copy writes a hidden temporary file and renames it into place.
        let operations = destinationService.operations
        let uploadPaths = operations.compactMap { operation -> String? in
            guard case .upload(let path, _, _) = operation else { return nil }
            return path
        }
        let uploadedPath = try #require(uploadPaths.first)
        #expect(uploadedPath != "/destination/file.txt")
        #expect(uploadedPath.hasPrefix("/destination/.file.txt.vvterm-upload-"))
        #expect(operations.contains(.renameItem(source: uploadedPath, destination: "/destination/file.txt")))
        #expect(!operations.contains(.deleteFile(uploadedPath)))
    }

    @Test
    func copyFileUploadMasksRemoteFileTypeBitsFromDestinationPermissions() async throws {
        let store = RemoteFileBrowserStore(
            persistedStateStore: RemoteFileBrowserPersistedStateStore(userDefaults: makeDefaults()),
            serverProvider: { _ in nil }
        )
        let sourceService = RecordingRemoteFileService(
            directoryContents: [:],
            downloadData: Data("copied payload".utf8)
        )
        let destinationService = RecordingRemoteFileService(directoryContents: [:])
        let sourceEntry = makeEntry(
            name: "script.sh",
            path: "/source/script.sh",
            type: .file,
            permissions: UInt32(LIBSSH2_SFTP_S_IFREG) | 0o750
        )

        // Given the source SFTP attributes include both file type bits and
        // access bits, as libssh2 commonly reports for remote entries.
        try await store.copyRemoteEntry(
            sourceEntry,
            to: "/destination",
            sourceService: sourceService,
            destinationService: destinationService,
            progressTracker: nil
        )

        // Then the destination upload receives only chmod-style permission
        // bits; file type bits must not leak into the create mode.
        #expect(destinationService.uploadPermissions == [0o750])
    }

    @Test
    func copyDirectoryCancellationDoesNotExposePartialDestinationDirectory() async throws {
        let store = RemoteFileBrowserStore(
            persistedStateStore: RemoteFileBrowserPersistedStateStore(userDefaults: makeDefaults()),
            serverProvider: { _ in nil }
        )
        let listBlocker = RemoteFileListBlocker(blockedPath: "/source/folder")
        let sourceService = RecordingRemoteFileService(
            directoryContents: [
                "/source/folder": [
                    makeEntry(name: "child.txt", path: "/source/folder/child.txt", type: .file)
                ]
            ],
            listBlocker: listBlocker,
            downloadData: Data("copied child".utf8)
        )
        let destinationService = RecordingRemoteFileService(directoryContents: [:])

        // Given a remote-to-remote directory copy has created its destination
        // staging directory but has not copied children yet.
        let task = Task {
            try await store.copyRemoteEntry(
                makeEntry(name: "folder", path: "/source/folder", type: .directory),
                to: "/destination",
                sourceService: sourceService,
                destinationService: destinationService,
                progressTracker: nil
            )
        }
        await listBlocker.waitUntilStarted()

        // When cancellation arrives before child entries are copied.
        task.cancel()
        await listBlocker.release()

        // Then the final destination directory is never exposed, and the
        // temporary staging directory is removed instead of being renamed.
        let result = await task.result
        switch result {
        case .success:
            Issue.record("Expected directory copy cancellation before final replacement")
        case .failure(is CancellationError):
            break
        case .failure(let error):
            Issue.record("Expected CancellationError, got \(error)")
        }

        let operations = destinationService.operations
        let createdPaths = operations.compactMap { operation -> String? in
            guard case .createDirectory(let path) = operation else { return nil }
            return path
        }
        let stagingPath = try #require(createdPaths.first)
        #expect(stagingPath != "/destination/folder")
        #expect(stagingPath.hasPrefix("/destination/.folder.vvterm-copy-"))
        #expect(operations.contains(.deleteDirectory(stagingPath)))
        #expect(!operations.contains(.renameItem(source: stagingPath, destination: "/destination/folder")))
    }

    @Test
    func copyEntriesResolvesDirectoryConflictBeforeAtomicRename() async throws {
        let sourceServer = Server(
            workspaceId: UUID(),
            name: "Source",
            host: "source.example.com",
            username: "root"
        )
        let destinationServer = Server(
            workspaceId: UUID(),
            name: "Destination",
            host: "destination.example.com",
            username: "root"
        )
        let sourceEntry = makeEntry(name: "folder", path: "/source/folder", type: .directory)
        let sourceService = RecordingRemoteFileService(
            directoryContents: [
                "/source/folder": []
            ]
        )
        let destinationService = RecordingRemoteFileService(
            directoryContents: [:],
            existingEntries: [
                "/destination/folder": makeEntry(name: "folder", path: "/destination/folder", type: .directory)
            ]
        )
        let services = ServerScopedRemoteFileServiceAccess(services: [
            sourceServer.id: sourceService,
            destinationServer.id: destinationService
        ])
        let store = RemoteFileBrowserStore(
            persistedStateStore: RemoteFileBrowserPersistedStateStore(userDefaults: makeDefaults()),
            remoteFileServiceAccess: services,
            serverProvider: { id in
                if id == sourceServer.id { return sourceServer }
                if id == destinationServer.id { return destinationServer }
                return nil
            }
        )
        let tab = RemoteFileTab(serverId: destinationServer.id, seedPath: "/destination")

        // Given the destination already contains a directory with the copied
        // entry's original name.
        try await store.copyEntries(
            [sourceEntry],
            from: sourceServer.id,
            to: "/destination",
            destinationTab: tab,
            destinationServer: destinationServer
        )

        // Then copy planning keeps both directories and atomically publishes the
        // staged copy under the resolved name.
        let operations = destinationService.operations
        let createdPaths = operations.compactMap { operation -> String? in
            guard case .createDirectory(let path) = operation else { return nil }
            return path
        }
        let stagingPath = try #require(createdPaths.first)
        #expect(stagingPath.hasPrefix("/destination/.folder 2.vvterm-copy-"))
        #expect(operations.contains(.renameItem(source: stagingPath, destination: "/destination/folder 2")))
        #expect(!operations.contains(.renameItem(source: stagingPath, destination: "/destination/folder")))
    }

    @Test
    func copyEntriesRetriesKeepBothNameWhenPublishDestinationAppearsDuringAtomicRename() async throws {
        let sourceServer = Server(
            workspaceId: UUID(),
            name: "Source",
            host: "source.example.com",
            username: "root"
        )
        let destinationServer = Server(
            workspaceId: UUID(),
            name: "Destination",
            host: "destination.example.com",
            username: "root"
        )
        let sourceEntry = makeEntry(name: "folder", path: "/source/folder", type: .directory)
        let sourceService = RecordingRemoteFileService(
            directoryContents: [
                "/source/folder": []
            ]
        )
        let destinationService = RecordingRemoteFileService(
            directoryContents: [:],
            existingEntries: [
                "/destination/folder": makeEntry(name: "folder", path: "/destination/folder", type: .directory)
            ],
            publishConflictDestinations: ["/destination/folder 2"]
        )
        let services = ServerScopedRemoteFileServiceAccess(services: [
            sourceServer.id: sourceService,
            destinationServer.id: destinationService
        ])
        let store = RemoteFileBrowserStore(
            persistedStateStore: RemoteFileBrowserPersistedStateStore(userDefaults: makeDefaults()),
            remoteFileServiceAccess: services,
            serverProvider: { id in
                if id == sourceServer.id { return sourceServer }
                if id == destinationServer.id { return destinationServer }
                return nil
            }
        )
        let tab = RemoteFileTab(serverId: destinationServer.id, seedPath: "/destination")

        // Given the originally resolved keep-both destination is created by
        // another client before the staged copy is atomically published.
        try await store.copyEntries(
            [sourceEntry],
            from: sourceServer.id,
            to: "/destination",
            destinationTab: tab,
            destinationServer: destinationServer
        )

        // Then copy retries conflict resolution instead of overwriting the
        // newly created destination.
        let operations = destinationService.operations
        let renameOperations = operations.compactMap { operation -> (source: String, destination: String)? in
            guard case .renameItem(let source, let destination) = operation else { return nil }
            return (source, destination)
        }
        #expect(renameOperations.map(\.destination) == [
            "/destination/folder 2",
            "/destination/folder 3"
        ])
        let failedStagingPath = try #require(renameOperations.first?.source)
        #expect(operations.contains(.deleteDirectory(failedStagingPath)))
    }

    @Test
    func downloadFileUsesSecurityScopedAccessForDestination() async throws {
        let server = Server(
            workspaceId: UUID(),
            name: "Production",
            host: "ssh.example.com",
            username: "root"
        )
        let destinationURL = URL(fileURLWithPath: "/Users/test/Downloads/report.txt")
        let localFileService = RecordingRemoteFileLocalFileService()
        let service = RecordingRemoteFileService(
            directoryContents: [:],
            downloadAccessProbe: {
                localFileService.isAccessing(destinationURL)
            }
        )
        let store = RemoteFileBrowserStore(
            persistedStateStore: RemoteFileBrowserPersistedStateStore(userDefaults: makeDefaults()),
            remoteFileServiceAccess: DirectRemoteFileServiceAccess(service: service),
            localFileService: localFileService,
            serverProvider: { _ in nil }
        )

        // Given macOS NSSavePanel returns a destination outside the sandbox.
        try await store.downloadFile(
            at: "/remote/report.txt",
            to: destinationURL,
            server: server
        )

        // Then the local file service owns the scoped write access while the
        // remote transfer writes to the destination, and releases it afterward.
        #expect(service.downloadObservedSecurityScope == true)
        #expect(localFileService.accessEvents(for: destinationURL) == [.start, .stop])
        #expect(!localFileService.isAccessing(destinationURL))
    }

    @Test
    func uploadFileCancellationDoesNotWriteFinalRemotePath() async throws {
        let store = RemoteFileBrowserStore(
            persistedStateStore: RemoteFileBrowserPersistedStateStore(userDefaults: makeDefaults()),
            serverProvider: { _ in nil }
        )
        let localDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteFileTransferCoordinatorTests-\(UUID().uuidString)", isDirectory: true)
        let localURL = localDirectory.appendingPathComponent("report.txt")
        try FileManager.default.createDirectory(at: localDirectory, withIntermediateDirectories: true)
        try Data("new remote contents".utf8).write(to: localURL)
        defer { try? FileManager.default.removeItem(at: localDirectory) }

        let uploadBlocker = RemoteFileUploadBlocker()
        let service = RecordingRemoteFileService(
            directoryContents: [:],
            uploadBlocker: uploadBlocker
        )

        // Given a local file upload has reached the remote write phase.
        let task = Task {
            try await store.uploadItem(
                at: localURL,
                to: "/remote",
                using: service
            )
        }
        await uploadBlocker.waitUntilStarted()

        // When cancellation arrives before the upload is allowed to finish.
        task.cancel()
        await uploadBlocker.release()

        // Then RemoteFiles never writes partial bytes to the final remote path,
        // and the temporary upload path is cleaned without being renamed.
        let result = await task.result
        switch result {
        case .success:
            Issue.record("Expected upload cancellation before final remote replacement")
        case .failure(is CancellationError):
            break
        case .failure(let error):
            Issue.record("Expected CancellationError, got \(error)")
        }

        let operations = service.operations
        let uploadPaths = operations.compactMap { operation -> String? in
            guard case .upload(let path, _, _) = operation else { return nil }
            return path
        }
        let uploadedPath = try #require(uploadPaths.first)
        #expect(uploadedPath != "/remote/report.txt")
        #expect(uploadedPath.hasPrefix("/remote/.report.txt.vvterm-upload-"))
        #expect(operations.contains(.deleteFile(uploadedPath)))
        #expect(!operations.contains(.renameItem(source: uploadedPath, destination: "/remote/report.txt")))
    }

    @Test
    func deleteEntriesCancellationStopsBeforeNextSelectedItem() async throws {
        let server = Server(
            workspaceId: UUID(),
            name: "Production",
            host: "ssh.example.com",
            username: "root"
        )
        let tab = RemoteFileTab(serverId: server.id, seedPath: "/remote")
        let deleteBlocker = RemoteFileDeleteBlocker(blockedPath: "/remote/first.txt")
        let service = RecordingRemoteFileService(
            directoryContents: [:],
            deleteBlocker: deleteBlocker
        )
        let store = RemoteFileBrowserStore(
            persistedStateStore: RemoteFileBrowserPersistedStateStore(userDefaults: makeDefaults()),
            remoteFileServiceAccess: DirectRemoteFileServiceAccess(service: service),
            serverProvider: { _ in nil }
        )
        let entries = [
            makeEntry(name: "first.txt", path: "/remote/first.txt", type: .file),
            makeEntry(name: "second.txt", path: "/remote/second.txt", type: .file)
        ]

        // Given batch deletion is blocked inside the first selected item.
        let task = Task {
            try await store.deleteEntries(entries, in: tab, server: server)
        }
        await deleteBlocker.waitUntilStarted()

        // When the batch operation is canceled before the first delete returns.
        task.cancel()
        await deleteBlocker.release()

        // Then cancellation is observed before deleting the next selected item.
        let result = await task.result
        #expect(service.operations == [
            .deleteFile("/remote/first.txt")
        ])
        switch result {
        case .success:
            Issue.record("Expected batch delete to stop after cancellation")
        case .failure(is CancellationError):
            break
        case .failure(let error):
            Issue.record("Expected CancellationError, got \(error)")
        }
    }

    @Test
    func moveEntriesCancellationStopsBeforeNextRename() async throws {
        let server = Server(
            workspaceId: UUID(),
            name: "Production",
            host: "ssh.example.com",
            username: "root"
        )
        let tab = RemoteFileTab(serverId: server.id, seedPath: "/target")
        let renameBlocker = RemoteFileRenameBlocker(blockedSourcePath: "/source/first.txt")
        let service = RecordingRemoteFileService(
            directoryContents: [:],
            renameBlocker: renameBlocker
        )
        let store = RemoteFileBrowserStore(
            persistedStateStore: RemoteFileBrowserPersistedStateStore(userDefaults: makeDefaults()),
            remoteFileServiceAccess: DirectRemoteFileServiceAccess(service: service),
            serverProvider: { _ in nil }
        )
        let moves = [
            RemoteFileDropPolicy.MovePlan(
                entry: makeEntry(name: "first.txt", path: "/source/first.txt", type: .file),
                sourcePath: "/source/first.txt",
                destinationPath: "/target/first.txt"
            ),
            RemoteFileDropPolicy.MovePlan(
                entry: makeEntry(name: "second.txt", path: "/source/second.txt", type: .file),
                sourcePath: "/source/second.txt",
                destinationPath: "/target/second.txt"
            )
        ]

        // Given same-server move is blocked inside the first rename.
        let task = Task {
            try await store.moveEntries(moves, in: tab, server: server)
        }
        await renameBlocker.waitUntilStarted()

        // When the move task is canceled before the first rename returns.
        task.cancel()
        await renameBlocker.release()

        // Then cancellation is observed before renaming the next dragged item.
        let result = await task.result
        #expect(service.operations == [
            .renameItem(source: "/source/first.txt", destination: "/target/first.txt")
        ])
        switch result {
        case .success:
            Issue.record("Expected same-server move to stop after cancellation")
        case .failure(is CancellationError):
            break
        case .failure(let error):
            Issue.record("Expected CancellationError, got \(error)")
        }
    }

    @Test
    func moveEntriesCoordinatorReportsPartialMutationOnCancellation() async throws {
        let coordinator = RemoteFileMoveEntriesCoordinator()
        let renameBlocker = RemoteFileRenameBlocker(blockedSourcePath: "/source/first.txt")
        let service = RecordingRemoteFileService(
            directoryContents: [:],
            renameBlocker: renameBlocker
        )
        let moves = [
            RemoteFileDropPolicy.MovePlan(
                entry: makeEntry(name: "first.txt", path: "/source/first.txt", type: .file),
                sourcePath: "/source/first.txt",
                destinationPath: "/target/first.txt"
            ),
            RemoteFileDropPolicy.MovePlan(
                entry: makeEntry(name: "second.txt", path: "/source/second.txt", type: .file),
                sourcePath: "/source/second.txt",
                destinationPath: "/target/second.txt"
            )
        ]
        var progressEvents: [String] = []

        // Given the dedicated move owner is blocked inside the first remote
        // rename after SFTP has accepted the operation.
        let task = Task {
            try await coordinator.moveEntries(moves, using: service) { progress in
                progressEvents.append(
                    "\(progress.completedUnitCount)/\(progress.totalUnitCount):\(progress.currentItemName)"
                )
            }
        }
        await renameBlocker.waitUntilStarted()

        // When the batch move is canceled before the first rename returns.
        task.cancel()
        await renameBlocker.release()

        // Then the owner reports that a remote mutation already happened while
        // preserving the underlying cancellation for the caller.
        let result = await task.result
        #expect(service.operations == [
            .renameItem(source: "/source/first.txt", destination: "/target/first.txt")
        ])
        #expect(progressEvents == ["1/2:first.txt"])
        switch result {
        case .success:
            Issue.record("Expected move owner to report partial mutation after cancellation")
        case .failure(let error):
            let failure = try #require(error as? RemoteFileMoveEntriesCoordinator.Failure)
            #expect(failure.didMutate)
            #expect(failure.underlyingError is CancellationError)
        }
    }

    private func makeEntry(
        name: String,
        path: String,
        type: RemoteFileType = .file,
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
        case upload(path: String, text: String, permissions: Int32)
        case createDirectory(String)
        case renameItem(source: String, destination: String)
        case deleteFile(String)
        case deleteDirectory(String)
    }

    let directoryContents: [String: [RemoteFileEntry]]
    let listBlocker: RemoteFileListBlocker?
    let downloadBlocker: RemoteFileDownloadBlocker?
    let uploadBlocker: RemoteFileUploadBlocker?
    let downloadData: Data?
    let renameBlocker: RemoteFileRenameBlocker?
    let deleteBlocker: RemoteFileDeleteBlocker?
    let downloadAccessProbe: (@Sendable () async -> Bool)?
    private let lock = NSLock()
    private var operationStorage: [Operation] = []
    private var downloadObservedSecurityScopeStorage: Bool?
    private var existingEntryStorage: [String: RemoteFileEntry]
    private let publishConflictDestinations: Set<String>
    private var triggeredPublishConflictDestinations: Set<String> = []

    var operations: [Operation] {
        lock.lock()
        defer { lock.unlock() }
        return operationStorage
    }

    var downloadObservedSecurityScope: Bool? {
        lock.lock()
        defer { lock.unlock() }
        return downloadObservedSecurityScopeStorage
    }

    var uploadPermissions: [Int32] {
        lock.lock()
        defer { lock.unlock() }
        return operationStorage.compactMap { operation in
            guard case .upload(_, _, let permissions) = operation else { return nil }
            return permissions
        }
    }

    init(
        directoryContents: [String: [RemoteFileEntry]],
        listBlocker: RemoteFileListBlocker? = nil,
        downloadBlocker: RemoteFileDownloadBlocker? = nil,
        uploadBlocker: RemoteFileUploadBlocker? = nil,
        downloadData: Data? = nil,
        renameBlocker: RemoteFileRenameBlocker? = nil,
        deleteBlocker: RemoteFileDeleteBlocker? = nil,
        existingEntries: [String: RemoteFileEntry] = [:],
        publishConflictDestinations: Set<String> = [],
        downloadAccessProbe: (@Sendable () async -> Bool)? = nil
    ) {
        self.directoryContents = directoryContents
        self.listBlocker = listBlocker
        self.downloadBlocker = downloadBlocker
        self.uploadBlocker = uploadBlocker
        self.downloadData = downloadData
        self.renameBlocker = renameBlocker
        self.deleteBlocker = deleteBlocker
        self.existingEntryStorage = existingEntries
        self.publishConflictDestinations = publishConflictDestinations
        self.downloadAccessProbe = downloadAccessProbe
    }

    func listDirectory(at path: String, maxEntries: Int?) async throws -> [RemoteFileEntry] {
        let normalizedPath = RemoteFilePath.normalize(path)
        await listBlocker?.waitIfNeeded(path: normalizedPath)
        return directoryContents[normalizedPath] ?? []
    }

    func stat(at path: String) async throws -> RemoteFileEntry {
        throw RemoteFileBrowserError.failed("Unused in tests")
    }

    func lstat(at path: String) async throws -> RemoteFileEntry {
        let normalizedPath = RemoteFilePath.normalize(path)
        guard let entry = lock.withLock({ existingEntryStorage[normalizedPath] }) else {
            throw RemoteFileBrowserError.pathNotFound
        }
        return entry
    }

    func readFile(at path: String, maxBytes: Int) async throws -> Data {
        Data()
    }

    func downloadFile(at path: String, to localURL: URL) async throws {
        let normalizedPath = RemoteFilePath.normalize(path)
        record(.downloadFile(normalizedPath))
        if let downloadAccessProbe {
            recordDownloadObservedSecurityScope(await downloadAccessProbe())
        }
        await downloadBlocker?.waitIfNeeded(path: normalizedPath)
        if let downloadData {
            try downloadData.write(to: localURL)
        }
    }

    func upload(
        _ data: Data,
        to remotePath: String,
        permissions: Int32,
        strategy: SSHUploadStrategy
    ) async throws {
        let normalizedPath = RemoteFilePath.normalize(remotePath)
        record(.upload(
            path: normalizedPath,
            text: String(data: data, encoding: .utf8) ?? "<binary>",
            permissions: permissions
        ))
        await uploadBlocker?.waitIfNeeded(path: normalizedPath)
    }

    func createDirectory(at path: String, permissions: Int32) async throws {
        record(.createDirectory(RemoteFilePath.normalize(path)))
    }

    func renameItem(at sourcePath: String, to destinationPath: String) async throws {
        let normalizedSource = RemoteFilePath.normalize(sourcePath)
        let normalizedDestination = RemoteFilePath.normalize(destinationPath)
        record(.renameItem(source: normalizedSource, destination: normalizedDestination))
        await renameBlocker?.waitIfNeeded(sourcePath: normalizedSource)
        if shouldCreatePublishConflict(at: normalizedDestination) {
            throw RemoteFileBrowserError.failed("Destination already exists.")
        }
    }

    func renameItemIfDestinationMissing(at sourcePath: String, to destinationPath: String) async throws {
        let normalizedDestination = RemoteFilePath.normalize(destinationPath)
        do {
            _ = try await lstat(at: normalizedDestination)
            throw RemoteFilePublishError.destinationExists(normalizedDestination)
        } catch let error as RemoteFileBrowserError where error == .pathNotFound {
            do {
                try await renameItem(at: sourcePath, to: normalizedDestination)
            } catch {
                if (try? await lstat(at: normalizedDestination)) != nil {
                    throw RemoteFilePublishError.destinationExists(normalizedDestination)
                }
                throw error
            }
        }
    }

    func deleteFile(at path: String) async throws {
        try Task.checkCancellation()
        let normalizedPath = RemoteFilePath.normalize(path)
        record(.deleteFile(normalizedPath))
        await deleteBlocker?.waitIfNeeded(path: normalizedPath)
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

    private func shouldCreatePublishConflict(at destinationPath: String) -> Bool {
        lock.withLock {
            guard publishConflictDestinations.contains(destinationPath),
                  !triggeredPublishConflictDestinations.contains(destinationPath)
            else { return false }

            triggeredPublishConflictDestinations.insert(destinationPath)
            existingEntryStorage[destinationPath] = RemoteFileEntry(
                name: URL(fileURLWithPath: destinationPath).lastPathComponent,
                path: destinationPath,
                type: .directory,
                size: nil,
                modifiedAt: nil,
                permissions: nil,
                symlinkTarget: nil
            )
            return true
        }
    }

    private func recordDownloadObservedSecurityScope(_ isAccessing: Bool) {
        lock.lock()
        downloadObservedSecurityScopeStorage = isAccessing
        lock.unlock()
    }
}

private final class RecordingRemoteFileLocalFileService: RemoteFileLocalFileServicing, @unchecked Sendable {
    enum AccessEvent: Equatable {
        case start
        case stop
    }

    private let lock = NSLock()
    private var eventsByURL: [URL: [AccessEvent]] = [:]
    private var activeURLs: Set<URL> = []

    func loadData(from url: URL) async throws -> Data {
        Data()
    }

    func itemInfo(at url: URL) async throws -> RemoteFileLocalItemInfo {
        RemoteFileLocalItemInfo(name: url.lastPathComponent, isDirectory: false)
    }

    func directoryContents(at url: URL) async throws -> [URL] {
        []
    }

    func createDirectory(at url: URL) async throws {}

    func removeItem(at url: URL) async throws {
        try? FileManager.default.removeItem(at: url)
    }

    func replaceItem(at destinationURL: URL, withItemAt sourceURL: URL) async throws {
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            _ = try FileManager.default.replaceItemAt(destinationURL, withItemAt: sourceURL)
        } else {
            try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
        }
    }

    func withSecurityScopedAccess<T>(
        to urls: [URL],
        operation: () async throws -> T
    ) async throws -> T {
        recordAccessStart(for: urls)
        defer {
            recordAccessStop(for: urls)
        }
        return try await operation()
    }

    func accessEvents(for url: URL) -> [AccessEvent] {
        lock.withLock {
            eventsByURL[url] ?? []
        }
    }

    func isAccessing(_ url: URL) -> Bool {
        lock.withLock {
            activeURLs.contains(url)
        }
    }

    private func recordAccessStart(for urls: [URL]) {
        lock.withLock {
            for url in urls {
                eventsByURL[url, default: []].append(.start)
                activeURLs.insert(url)
            }
        }
    }

    private func recordAccessStop(for urls: [URL]) {
        lock.withLock {
            for url in urls {
                activeURLs.remove(url)
                eventsByURL[url, default: []].append(.stop)
            }
        }
    }
}

private actor RemoteFileListBlocker {
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

@MainActor
private final class DirectRemoteFileServiceAccess: RemoteFileServiceAccessing {
    private let service: any RemoteFileService

    init(service: any RemoteFileService) {
        self.service = service
    }

    func withService<T: Sendable>(
        for server: Server,
        operation: @Sendable @escaping (any RemoteFileService) async throws -> T
    ) async throws -> T {
        try await operation(service)
    }

    func disconnect(serverId: UUID) async {}

    func disconnectAll() async {}
}

@MainActor
private final class ServerScopedRemoteFileServiceAccess: RemoteFileServiceAccessing {
    private let services: [UUID: any RemoteFileService]

    init(services: [UUID: any RemoteFileService]) {
        self.services = services
    }

    func withService<T: Sendable>(
        for server: Server,
        operation: @Sendable @escaping (any RemoteFileService) async throws -> T
    ) async throws -> T {
        guard let service = services[server.id] else {
            throw RemoteFileBrowserError.disconnected
        }
        return try await operation(service)
    }

    func disconnect(serverId: UUID) async {}

    func disconnectAll() async {}
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

private actor RemoteFileUploadBlocker {
    private var started = false
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func waitIfNeeded(path: String) async {
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

private actor RemoteFileDeleteBlocker {
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

private actor RemoteFileRenameBlocker {
    let blockedSourcePath: String
    private var started = false
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    init(blockedSourcePath: String) {
        self.blockedSourcePath = blockedSourcePath
    }

    func waitIfNeeded(sourcePath: String) async {
        guard sourcePath == blockedSourcePath else { return }
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
