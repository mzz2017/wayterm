import Combine
import Foundation

extension RemoteFileBrowserStore {
    final class TransferProgressTracker {
        private(set) var completedUnitCount = 0
        let totalUnitCount: Int
        let onProgress: (@MainActor @Sendable (TransferProgress) -> Void)?

        init(
            totalUnitCount: Int,
            onProgress: (@MainActor @Sendable (TransferProgress) -> Void)?
        ) {
            self.totalUnitCount = max(1, totalUnitCount)
            self.onProgress = onProgress
        }

        @MainActor
        func advance(currentItemName: String) {
            completedUnitCount += 1
            onProgress?(
                TransferProgress(
                    completedUnitCount: min(completedUnitCount, totalUnitCount),
                    totalUnitCount: totalUnitCount,
                    currentItemName: currentItemName
                )
            )
        }
    }

    private var deletionCoordinator: RemoteFileDeletionCoordinator {
        RemoteFileDeletionCoordinator()
    }

    private var deleteEntriesCoordinator: RemoteFileDeleteEntriesCoordinator {
        RemoteFileDeleteEntriesCoordinator(deletionCoordinator: deletionCoordinator)
    }

    private var moveEntriesCoordinator: RemoteFileMoveEntriesCoordinator {
        RemoteFileMoveEntriesCoordinator()
    }

    private var copyEntriesCoordinator: RemoteFileCopyEntriesCoordinator {
        RemoteFileCopyEntriesCoordinator(conflictResolver: conflictResolver)
    }

    func upload(
        data: Data,
        to remotePath: String,
        server: Server,
        permissions: Int32 = 0o600,
        strategy: SSHUploadStrategy = .automatic
    ) async throws {
        try await withRemoteFileService(for: server) { service in
            try await service.upload(
                data,
                to: remotePath,
                permissions: permissions,
                strategy: strategy
            )
        }
    }

    func upload(
        fileAt localURL: URL,
        to remoteDirectoryPath: String,
        server: Server,
        permissions: Int32 = 0o600,
        strategy: SSHUploadStrategy = .automatic
    ) async throws {
        let remotePath = RemoteFilePath.appending(localURL.lastPathComponent, to: remoteDirectoryPath)
        let data = try await loadLocalFileData(from: localURL)
        try await upload(
            data: data,
            to: remotePath,
            server: server,
            permissions: permissions,
            strategy: strategy
        )
    }

    func createDirectory(
        at remotePath: String,
        in tab: RemoteFileTab,
        server: Server,
        permissions: Int32 = 0o755
    ) async throws {
        try await performMutation(in: tab, server: server) { service in
            try await service.createDirectory(at: remotePath, permissions: permissions)
        }
    }

    func createDirectory(
        named directoryName: String,
        in remoteDirectoryPath: String,
        tab: RemoteFileTab,
        server: Server,
        permissions: Int32 = 0o755
    ) async throws {
        let remotePath = RemoteFilePath.appending(
            try validatedRemoteName(directoryName),
            to: remoteDirectoryPath
        )
        try await createDirectory(at: remotePath, in: tab, server: server, permissions: permissions)
    }

    func renameItem(
        at sourcePath: String,
        to destinationPath: String,
        in tab: RemoteFileTab,
        server: Server
    ) async throws {
        try await performMutation(in: tab, server: server) { service in
            try await service.renameItem(at: sourcePath, to: destinationPath)
        }
    }

    func moveEntries(
        _ moves: [RemoteFileDropPolicy.MovePlan],
        in tab: RemoteFileTab,
        server: Server,
        onProgress: (@MainActor @Sendable (TransferProgress) -> Void)? = nil
    ) async throws {
        guard tab.serverId == server.id else {
            throw RemoteFileBrowserError.disconnected
        }
        guard !moves.isEmpty else { return }

        do {
            try await withRemoteFileService(for: server) { [self] service in
                try await moveEntriesCoordinator.moveEntries(
                    moves,
                    using: service,
                    onProgress: onProgress
                )
            }
        } catch let failure as RemoteFileMoveEntriesCoordinator.Failure {
            if failure.didMutate {
                await refresh(server: server, tab: tab)
            }
            throw failure.underlyingError
        } catch {
            throw error
        }

        await refresh(server: server, tab: tab)
    }

    func deleteFile(
        at remotePath: String,
        in tab: RemoteFileTab,
        server: Server
    ) async throws {
        try await performMutation(in: tab, server: server) { service in
            try await service.deleteFile(at: remotePath)
        }
    }

    func deleteDirectory(
        at remotePath: String,
        in tab: RemoteFileTab,
        server: Server
    ) async throws {
        try await performMutation(in: tab, server: server) { [self] service in
            try await deleteDirectoryRecursively(at: remotePath, using: service)
        }
    }

    func deleteItem(
        at remotePath: String,
        in tab: RemoteFileTab,
        server: Server,
        type: RemoteFileType? = nil
    ) async throws {
        try await performMutation(in: tab, server: server) { [self] service in
            try await deletionCoordinator.deleteItem(
                at: remotePath,
                type: type,
                using: service
            )
        }
    }

    func deleteEntries(
        _ entries: [RemoteFileEntry],
        in tab: RemoteFileTab,
        server: Server
    ) async throws {
        guard tab.serverId == server.id else {
            throw RemoteFileBrowserError.disconnected
        }

        let uniqueEntries = transferPolicy.uniqueTransferEntries(entries)
        guard !uniqueEntries.isEmpty else { return }

        do {
            try await withRemoteFileService(for: server) { [self] service in
                try await deleteEntriesCoordinator.deleteEntries(uniqueEntries, using: service)
            }
        } catch let failure as RemoteFileDeleteEntriesCoordinator.Failure {
            if failure.didMutate {
                await refresh(server: server, tab: tab)
            }
            throw failure.underlyingError
        } catch {
            throw error
        }

        await refresh(server: server, tab: tab)
    }

    func setPermissions(
        _ entry: RemoteFileEntry,
        permissions: UInt32,
        in tab: RemoteFileTab,
        server: Server
    ) async throws {
        guard tab.serverId == server.id else {
            throw RemoteFileBrowserError.disconnected
        }

        let updatedEntry = try await withRemoteFileService(for: server) { service in
            try await service.setPermissions(at: entry.path, permissions: permissions)
            return try await service.lstat(at: entry.path)
        }

        let requestedPermissionBits = permissions & 0o7777
        let updatedPermissionBits = (updatedEntry.permissions ?? 0) & 0o7777
        if updatedPermissionBits != requestedPermissionBits {
            throw RemoteFileBrowserError.failed(
                String(
                    localized: "This server accepted the request, but the file permissions did not change. Some remote systems, including many Windows SFTP servers, do not support POSIX chmod."
                )
            )
        }

        updateState(for: tab) { state in
            if let index = state.entries.firstIndex(where: { $0.path == entry.path }) {
                state.entries[index] = updatedEntry
            }

            if state.selectedEntryPath == entry.path,
               let payload = state.viewerPayload,
               payload.entry.path == entry.path {
                state.viewerPayload = RemoteFileViewerPayload(
                    previewKind: payload.previewKind,
                    entry: updatedEntry,
                    textPreview: payload.textPreview,
                    previewFileURL: payload.previewFileURL,
                    isTruncated: payload.isTruncated,
                    unavailableMessage: payload.unavailableMessage,
                    requiresExplicitDownload: payload.requiresExplicitDownload,
                    previewByteCount: payload.previewByteCount
                )
            }
        }
    }

    func uploadFiles(
        at urls: [URL],
        to directoryPath: String,
        in tab: RemoteFileTab,
        server: Server,
        onProgress: (@MainActor @Sendable (TransferProgress) -> Void)? = nil
    ) async throws {
        let plans = transferPolicy.uploadPlans(for: urls)
        try await uploadFiles(
            plans: plans,
            to: directoryPath,
            in: tab,
            server: server,
            onProgress: onProgress
        )
    }

    func uploadFiles(
        plans: [LocalUploadPlanItem],
        to directoryPath: String,
        in tab: RemoteFileTab,
        server: Server,
        onProgress: (@MainActor @Sendable (TransferProgress) -> Void)? = nil
    ) async throws {
        guard tab.serverId == server.id else {
            throw RemoteFileBrowserError.disconnected
        }

        let destinationDirectory = RemoteFilePath.normalize(directoryPath)
        let urls = plans.map(\.sourceURL)
        try await localFileService.withSecurityScopedAccess(to: urls) {
            let progressTracker = TransferProgressTracker(
                totalUnitCount: try await countLocalTransferUnits(at: urls),
                onProgress: onProgress
            )
            try await withRemoteFileService(for: server) { [self] service in
                for plan in plans {
                    try Task.checkCancellation()
                    try await self.uploadItem(
                        at: plan.sourceURL,
                        to: destinationDirectory,
                        remoteName: plan.remoteName,
                        using: service,
                        progressTracker: progressTracker
                    )
                }
            }
        }

        clearViewer(for: tab)
        await refresh(server: server, tab: tab)
    }

    func prepareLocalUploadPlan(
        at urls: [URL],
        to directoryPath: String,
        server: Server
    ) async throws -> [LocalUploadPlanCandidate] {
        let destinationDirectory = RemoteFilePath.normalize(directoryPath)
        return try await localFileService.withSecurityScopedAccess(to: urls) {
            try await withRemoteFileService(for: server) { service in
                var reservedNames: Set<String> = []
                var candidates: [LocalUploadPlanCandidate] = []

                for url in urls {
                    try Task.checkCancellation()
                    let itemInfo = try await self.localItemInfo(at: url)
                    let originalName = itemInfo.name
                    let resolution = try await self.conflictResolver.resolveName(
                        for: originalName,
                        in: destinationDirectory,
                        policy: .keepBoth,
                        using: service,
                        reservedNames: &reservedNames
                    )
                    candidates.append(
                        LocalUploadPlanCandidate(
                            sourceURL: url,
                            originalName: originalName,
                            existingEntry: resolution.existingEntry,
                            suggestedName: resolution.hasConflict ? resolution.resolvedName : nil
                        )
                    )
                }

                return candidates
            }
        }
    }

    func copyEntries(
        _ entries: [RemoteFileEntry],
        from sourceServerId: UUID,
        to destinationDirectoryPath: String,
        destinationTab: RemoteFileTab,
        destinationServer: Server,
        onProgress: (@MainActor @Sendable (TransferProgress) -> Void)? = nil
    ) async throws {
        guard destinationTab.serverId == destinationServer.id,
              let sourceServer = server(for: sourceServerId) else {
            throw RemoteFileBrowserError.disconnected
        }

        let uniqueEntries = transferPolicy.uniqueTransferEntries(entries)
        guard !uniqueEntries.isEmpty else { return }

        let destinationDirectory = RemoteFilePath.normalize(destinationDirectoryPath)
        let totalUnitCount = try await withRemoteFileService(for: sourceServer) { service in
            try await self.countRemoteTransferUnits(for: uniqueEntries, using: service)
        }
        let progressTracker = TransferProgressTracker(
            totalUnitCount: totalUnitCount,
            onProgress: onProgress
        )

        try await withRemoteFileService(for: sourceServer) { sourceService in
            try await self.withRemoteFileService(for: destinationServer) { destinationService in
                try await self.copyEntriesCoordinator.copyEntries(
                    uniqueEntries,
                    to: destinationDirectory,
                    using: destinationService,
                    progressTracker: progressTracker
                ) { entry, remoteName, progressTracker in
                    try await self.copyRemoteEntry(
                        entry,
                        to: destinationDirectory,
                        remoteName: remoteName,
                        sourceService: sourceService,
                        destinationService: destinationService,
                        progressTracker: progressTracker
                    )
                }
            }
        }

        clearViewer(for: destinationTab)
        await refresh(server: destinationServer, tab: destinationTab)
    }

    func downloadFile(
        at remotePath: String,
        to localURL: URL,
        server: Server
    ) async throws {
        try await localFileService.withSecurityScopedAccess(to: [localURL]) {
            try await withRemoteFileService(for: server) { service in
                try await service.downloadFile(at: remotePath, to: localURL)
            }
        }
    }

    func downloadItem(
        _ entry: RemoteFileEntry,
        to localURL: URL,
        server: Server
    ) async throws {
        try await localFileService.withSecurityScopedAccess(to: [localURL]) {
            try await withRemoteFileService(for: server) { service in
                try await self.downloadItem(entry, to: localURL, using: service)
            }
        }
    }

    func listDirectories(
        at path: String,
        server: Server
    ) async throws -> [RemoteFileEntry] {
        let normalizedPath = RemoteFilePath.normalize(path)
        let entries = try await withRemoteFileService(for: server) { service in
            try await service.listDirectory(at: normalizedPath, maxEntries: Self.directoryEntryLimit)
        }
        return entries
            .filter { $0.type == .directory }
            .sortedForBrowser(using: .name, direction: .ascending)
    }

    func performMutation(
        in tab: RemoteFileTab,
        server: Server,
        operation: @Sendable @escaping (any RemoteFileService) async throws -> Void
    ) async throws {
        guard tab.serverId == server.id else {
            throw RemoteFileBrowserError.disconnected
        }

        try await withRemoteFileService(for: server) { service in
            try await operation(service)
        }
        await refresh(server: server, tab: tab)
    }

    func deleteDirectoryRecursively(
        at remotePath: String,
        using service: any RemoteFileService
    ) async throws {
        try await deletionCoordinator.deleteDirectoryRecursively(at: remotePath, using: service)
    }

    private var recursiveTransferCoordinator: RemoteFileRecursiveTransferCoordinator {
        RemoteFileRecursiveTransferCoordinator(
            localFileService: localFileService,
            temporaryStorage: temporaryStorage
        )
    }

    func loadLocalFileData(from url: URL) async throws -> Data {
        try await recursiveTransferCoordinator.loadLocalFileData(from: url)
    }

    func localItemInfo(at url: URL) async throws -> RemoteFileLocalItemInfo {
        try await recursiveTransferCoordinator.localItemInfo(at: url)
    }

    func localDirectoryContents(at url: URL) async throws -> [URL] {
        try await recursiveTransferCoordinator.localDirectoryContents(at: url)
    }

    func uploadItem(
        at localURL: URL,
        to remoteDirectoryPath: String,
        remoteName: String? = nil,
        using client: any RemoteFileService,
        progressTracker: TransferProgressTracker? = nil
    ) async throws {
        try await recursiveTransferCoordinator.uploadItem(
            at: localURL,
            to: remoteDirectoryPath,
            remoteName: remoteName,
            using: client,
            progressTracker: progressTracker
        )
    }

    func downloadItem(
        _ entry: RemoteFileEntry,
        to localURL: URL,
        using service: any RemoteFileService
    ) async throws {
        try await recursiveTransferCoordinator.downloadItem(entry, to: localURL, using: service)
    }

    func copyRemoteEntry(
        _ entry: RemoteFileEntry,
        to remoteDirectoryPath: String,
        remoteName: String? = nil,
        sourceService: any RemoteFileService,
        destinationService: any RemoteFileService,
        progressTracker: TransferProgressTracker?
    ) async throws {
        try await recursiveTransferCoordinator.copyRemoteEntry(
            entry,
            to: remoteDirectoryPath,
            remoteName: remoteName,
            sourceService: sourceService,
            destinationService: destinationService,
            progressTracker: progressTracker
        )
    }

    func countLocalTransferUnits(at urls: [URL]) async throws -> Int {
        var totalUnitCount = 0

        for url in urls {
            try Task.checkCancellation()
            totalUnitCount += try await countLocalTransferUnits(at: url)
        }

        return max(1, totalUnitCount)
    }

    func countLocalTransferUnits(at url: URL) async throws -> Int {
        let itemInfo = try await localItemInfo(at: url)
        guard itemInfo.isDirectory else { return 1 }

        let children = try await localDirectoryContents(at: url)
        var totalUnitCount = 1

        for child in children {
            try Task.checkCancellation()
            totalUnitCount += try await countLocalTransferUnits(at: child)
        }

        return totalUnitCount
    }

    func countRemoteTransferUnits(
        for entries: [RemoteFileEntry],
        using client: any RemoteFileService
    ) async throws -> Int {
        try await recursiveTransferCoordinator.countRemoteTransferUnits(for: entries, using: client)
    }

    func countRemoteTransferUnits(
        for entry: RemoteFileEntry,
        using client: any RemoteFileService
    ) async throws -> Int {
        try await recursiveTransferCoordinator.countRemoteTransferUnits(for: entry, using: client)
    }

    func resolvedTransferEntry(
        for entry: RemoteFileEntry,
        using client: any RemoteFileService
    ) async throws -> RemoteFileEntry {
        try await recursiveTransferCoordinator.resolvedTransferEntry(for: entry, using: client)
    }

    func ensureRemoteDirectoryExists(
        at remotePath: String,
        permissions: Int32,
        using client: any RemoteFileService
    ) async throws {
        try await recursiveTransferCoordinator.ensureRemoteDirectoryExists(
            at: remotePath,
            permissions: permissions,
            using: client
        )
    }

    func uniqueTransferEntries(_ entries: [RemoteFileEntry]) -> [RemoteFileEntry] {
        transferPolicy.uniqueTransferEntries(entries)
    }

    func createLocalDirectory(at url: URL) async throws {
        try await recursiveTransferCoordinator.createLocalDirectory(at: url)
    }

    nonisolated func makeDownloadExportFileURL(for entry: RemoteFileEntry) throws -> URL {
        try temporaryStorage.makeDownloadExportFileURL(for: entry)
    }

    nonisolated func makeDragExportFileURL(for entry: RemoteFileEntry) throws -> URL {
        try temporaryStorage.makeDragExportFileURL(for: entry)
    }

    nonisolated func removeTemporaryFile(at url: URL) {
        temporaryStorage.removeItem(at: url)
    }

    func validatedRemoteName(_ name: String) throws -> String {
        try transferPolicy.validatedRemoteName(name)
    }

    func validatedRemoteDirectoryPath(_ path: String, relativeTo currentPath: String) throws -> String {
        try transferPolicy.validatedRemoteDirectoryPath(path, relativeTo: currentPath)
    }
}
