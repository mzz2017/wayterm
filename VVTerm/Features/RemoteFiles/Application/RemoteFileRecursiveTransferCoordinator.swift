import Foundation

@MainActor
struct RemoteFileRecursiveTransferCoordinator {
    typealias TransferProgressTracker = RemoteFileBrowserStore.TransferProgressTracker

    let localFileService: any RemoteFileLocalFileServicing
    let temporaryStorage: RemoteFileTemporaryStorage
    let atomicUploader: RemoteFileAtomicUploader

    init(
        localFileService: any RemoteFileLocalFileServicing,
        temporaryStorage: RemoteFileTemporaryStorage,
        atomicUploader: RemoteFileAtomicUploader = RemoteFileAtomicUploader()
    ) {
        self.localFileService = localFileService
        self.temporaryStorage = temporaryStorage
        self.atomicUploader = atomicUploader
    }

    func uploadItem(
        at localURL: URL,
        to remoteDirectoryPath: String,
        remoteName: String? = nil,
        using client: any RemoteFileService,
        progressTracker: TransferProgressTracker? = nil
    ) async throws {
        let itemInfo = try await localItemInfo(at: localURL)
        let targetName = remoteName ?? itemInfo.name
        let remotePath = RemoteFilePath.appending(targetName, to: remoteDirectoryPath)

        if itemInfo.isDirectory {
            try await ensureRemoteDirectoryExists(
                at: remotePath,
                permissions: 0o755,
                using: client
            )
            progressTracker?.advance(currentItemName: targetName)
            let children = try await localDirectoryContents(at: localURL)
            for child in children {
                try Task.checkCancellation()
                try await uploadItem(
                    at: child,
                    to: remotePath,
                    using: client,
                    progressTracker: progressTracker
                )
            }
            return
        }

        let data = try await loadLocalFileData(from: localURL)
        try await atomicUploader.uploadAtomically(data, to: remotePath, permissions: Int32(0o644), using: client)
        progressTracker?.advance(currentItemName: targetName)
    }

    func downloadItem(
        _ entry: RemoteFileEntry,
        to localURL: URL,
        using service: any RemoteFileService
    ) async throws {
        let effectiveEntry = try await resolvedTransferEntry(for: entry, using: service)

        if effectiveEntry.type == .directory {
            let temporaryURL = try await makeAtomicDirectoryDownloadURL(for: localURL)
            do {
                try await createLocalDirectory(at: temporaryURL)
                try await downloadDirectoryContents(
                    of: entry,
                    to: temporaryURL,
                    using: service
                )
                try Task.checkCancellation()
                try await localFileService.replaceItem(at: localURL, withItemAt: temporaryURL)
            } catch {
                try? await localFileService.removeItem(at: temporaryURL)
                throw error
            }
            return
        }

        try await service.downloadFile(at: entry.path, to: localURL)
    }

    func copyRemoteEntry(
        _ entry: RemoteFileEntry,
        to remoteDirectoryPath: String,
        remoteName: String? = nil,
        sourceService: any RemoteFileService,
        destinationService: any RemoteFileService,
        progressTracker: TransferProgressTracker?
    ) async throws {
        let effectiveEntry = try await resolvedTransferEntry(for: entry, using: sourceService)
        let targetName = remoteName ?? entry.name
        let remotePath = RemoteFilePath.appending(targetName, to: remoteDirectoryPath)

        if effectiveEntry.type == .directory {
            let temporaryRemotePath = makeAtomicRemoteDirectoryCopyPath(for: remotePath)
            do {
                try await destinationService.createDirectory(
                    at: temporaryRemotePath,
                    permissions: modeBits(from: effectiveEntry.permissions, fallback: 0o755)
                )
                let children = try await sourceService.listDirectory(at: entry.path, maxEntries: nil)
                for child in children {
                    try Task.checkCancellation()
                    try await copyRemoteEntry(
                        child,
                        to: temporaryRemotePath,
                        sourceService: sourceService,
                        destinationService: destinationService,
                        progressTracker: progressTracker
                    )
                }
                try Task.checkCancellation()
                try await atomicUploader.publishAtomicRemoteItem(
                    at: temporaryRemotePath,
                    to: remotePath,
                    publishMode: .failIfDestinationExists,
                    using: destinationService
                )
                progressTracker?.advance(currentItemName: targetName)
            } catch {
                await removeAtomicRemoteDirectory(temporaryRemotePath, using: destinationService)
                throw error
            }
            return
        }

        let temporaryURL = try temporaryStorage.makeTransferFileURL(for: entry)
        defer { temporaryStorage.removeItem(at: temporaryURL) }

        try await sourceService.downloadFile(at: entry.path, to: temporaryURL)
        try Task.checkCancellation()
        let data = try await loadLocalFileData(from: temporaryURL)
        try await atomicUploader.uploadAtomically(
            data,
            to: remotePath,
            permissions: modeBits(from: effectiveEntry.permissions, fallback: 0o644),
            strategy: .automatic,
            publishMode: .failIfDestinationExists,
            using: destinationService
        )
        progressTracker?.advance(currentItemName: targetName)
    }

    func countRemoteTransferUnits(
        for entries: [RemoteFileEntry],
        using client: any RemoteFileService
    ) async throws -> Int {
        var totalUnitCount = 0

        for entry in entries {
            try Task.checkCancellation()
            totalUnitCount += try await countRemoteTransferUnits(for: entry, using: client)
        }

        return max(1, totalUnitCount)
    }

    func countRemoteTransferUnits(
        for entry: RemoteFileEntry,
        using client: any RemoteFileService
    ) async throws -> Int {
        let effectiveEntry = try await resolvedTransferEntry(for: entry, using: client)
        guard effectiveEntry.type == .directory else { return 1 }

        let children = try await client.listDirectory(at: entry.path, maxEntries: nil)
        var totalUnitCount = 1

        for child in children {
            try Task.checkCancellation()
            totalUnitCount += try await countRemoteTransferUnits(for: child, using: client)
        }

        return totalUnitCount
    }

    func resolvedTransferEntry(
        for entry: RemoteFileEntry,
        using client: any RemoteFileService
    ) async throws -> RemoteFileEntry {
        guard entry.type == .symlink else { return entry }

        let resolvedEntry = try await client.stat(at: entry.path)
        return RemoteFileEntry(
            name: entry.name,
            path: entry.path,
            type: resolvedEntry.type,
            size: resolvedEntry.size,
            modifiedAt: resolvedEntry.modifiedAt,
            permissions: resolvedEntry.permissions,
            symlinkTarget: entry.symlinkTarget ?? resolvedEntry.symlinkTarget
        )
    }

    func ensureRemoteDirectoryExists(
        at remotePath: String,
        permissions: Int32,
        using client: any RemoteFileService
    ) async throws {
        do {
            let existingEntry = try await client.lstat(at: remotePath)
            guard existingEntry.type == .directory else {
                throw RemoteFileBrowserError.failed(
                    String(
                        format: String(localized: "\"%@\" already exists and is not a folder."),
                        existingEntry.name.isEmpty ? remotePath : existingEntry.name
                    )
                )
            }
        } catch let error as RemoteFileBrowserError {
            guard case .pathNotFound = error else { throw error }
            try await client.createDirectory(at: remotePath, permissions: permissions)
        } catch {
            throw error
        }
    }

    func loadLocalFileData(from url: URL) async throws -> Data {
        try await localFileService.loadData(from: url)
    }

    func localItemInfo(at url: URL) async throws -> RemoteFileLocalItemInfo {
        try await localFileService.itemInfo(at: url)
    }

    func localDirectoryContents(at url: URL) async throws -> [URL] {
        try await localFileService.directoryContents(at: url)
    }

    func createLocalDirectory(at url: URL) async throws {
        try await localFileService.createDirectory(at: url)
    }

    private func downloadDirectoryContents(
        of entry: RemoteFileEntry,
        to localURL: URL,
        using service: any RemoteFileService
    ) async throws {
        let children = try await service.listDirectory(at: entry.path, maxEntries: nil)
        for child in children {
            try Task.checkCancellation()
            let childURL = localURL.appendingPathComponent(
                child.name,
                isDirectory: child.type == .directory
            )
            try await downloadItem(child, to: childURL, using: service)
        }
    }

    private func makeAtomicDirectoryDownloadURL(for destinationURL: URL) async throws -> URL {
        let parentURL = destinationURL.deletingLastPathComponent()
        try await createLocalDirectory(at: parentURL)
        return parentURL.appendingPathComponent(
            ".\(destinationURL.lastPathComponent).vvterm-download-\(UUID().uuidString).tmp",
            isDirectory: true
        )
    }

    private func modeBits(from permissions: UInt32?, fallback: Int32) -> Int32 {
        guard let permissions else { return fallback }
        return Int32(permissions & 0o7777)
    }

    private func removeAtomicRemoteDirectory(
        _ temporaryRemotePath: String,
        using service: any RemoteFileService
    ) async {
        let cleanupTask = Task.detached {
            await Self.deleteRemoteDirectoryRecursivelyIgnoringCancellation(
                at: temporaryRemotePath,
                using: service
            )
        }
        await cleanupTask.value
    }

    private nonisolated static func deleteRemoteDirectoryRecursivelyIgnoringCancellation(
        at remotePath: String,
        using service: any RemoteFileService
    ) async {
        do {
            let normalizedPath = RemoteFilePath.normalize(remotePath)
            let entries = try await service.listDirectory(at: normalizedPath, maxEntries: nil)

            for entry in entries {
                switch entry.type {
                case .directory:
                    await deleteRemoteDirectoryRecursivelyIgnoringCancellation(at: entry.path, using: service)
                case .file, .symlink, .other:
                    try? await service.deleteFile(at: entry.path)
                }
            }

            try? await service.deleteDirectory(at: normalizedPath)
        } catch {
            try? await service.deleteDirectory(at: RemoteFilePath.normalize(remotePath))
        }
    }

    private func makeAtomicRemoteDirectoryCopyPath(for remotePath: String) -> String {
        let normalizedPath = RemoteFilePath.normalize(remotePath)
        let parentPath = RemoteFilePath.parent(of: normalizedPath)
        let targetName = normalizedPath.split(separator: "/").last.map(String.init) ?? "copy"
        return RemoteFilePath.appending(
            ".\(targetName).vvterm-copy-\(UUID().uuidString).tmp",
            to: parentPath
        )
    }
}
