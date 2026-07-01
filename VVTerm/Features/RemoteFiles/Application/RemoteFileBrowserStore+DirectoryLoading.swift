import Foundation
import os.log

extension RemoteFileBrowserStore {
    func loadInitialPath(for server: Server, tab: RemoteFileTab, initialPath: String? = nil) async {
        guard tab.serverId == server.id else { return }

        let currentState = state(for: tab)
        guard !currentState.isLoadingDirectory else { return }
        guard !currentState.hasLoadedDirectory else { return }

        let requestID = directoryLoadCoordinator.beginRequest(for: tab.id)

        updateState(for: tab) { state in
            state.isLoadingDirectory = true
            state.error = nil
        }

        do {
            let snapshot = try await resolveInitialDirectorySnapshot(for: server, tab: tab, initialPath: initialPath)
            guard isCurrentDirectoryLoadRequest(requestID, for: tab.id) else { return }
            applyDirectorySnapshot(snapshot, to: tab)
        } catch {
            guard isCurrentDirectoryLoadRequest(requestID, for: tab.id) else { return }
            logger.error("Initial file browser load failed for \(server.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            updateState(for: tab) { state in
                state.isLoadingDirectory = false
                state.error = RemoteFileBrowserError.map(error)
            }
        }
    }

    func refresh(server: Server, tab: RemoteFileTab) async {
        guard tab.serverId == server.id else { return }
        let targetPath = lastVisitedPath(for: tab)
            ?? bestWorkingDirectory(for: server.id)
            ?? "/"
        await loadDirectory(path: targetPath, in: tab, server: server)
    }

    func openBreadcrumb(_ breadcrumb: RemoteFileBreadcrumb, in tab: RemoteFileTab, server: Server) async {
        guard tab.serverId == server.id else { return }
        await loadDirectory(path: breadcrumb.path, in: tab, server: server)
    }

    func openDirectory(_ entry: RemoteFileEntry, in tab: RemoteFileTab, server: Server) async {
        guard tab.serverId == server.id else { return }
        await loadDirectory(path: entry.path, in: tab, server: server)
    }

    func activate(_ entry: RemoteFileEntry, in tab: RemoteFileTab, server: Server) async {
        guard tab.serverId == server.id else { return }

        switch entry.type {
        case .directory:
            await openDirectory(entry, in: tab, server: server)
        case .symlink:
            do {
                let resolvedEntry = try await withRemoteFileService(for: server) { service in
                    try await service.stat(at: entry.path)
                }
                if resolvedEntry.type == .directory {
                    await loadDirectory(path: entry.path, in: tab, server: server)
                } else {
                    selectFile(entry, in: tab)
                }
            } catch {
                selectFile(entry, in: tab)
            }
        case .file, .other:
            selectFile(entry, in: tab)
        }
    }

    func goUp(in tab: RemoteFileTab, server: Server) async {
        guard tab.serverId == server.id else { return }
        let currentPath = currentPath(for: tab)
        let parentPath = RemoteFilePath.parent(of: currentPath)
        guard parentPath != currentPath else { return }
        await loadDirectory(path: parentPath, in: tab, server: server)
    }

    func loadDirectory(path: String, in tab: RemoteFileTab, server: Server) async {
        guard tab.serverId == server.id else { return }

        let normalizedPath = RemoteFilePath.normalize(path)
        cancelPreviewLoadRequest(for: tab.id)
        let requestID = directoryLoadCoordinator.beginRequest(for: tab.id)
        cleanupPreviewArtifact(for: state(for: tab).viewerPayload)

        updateState(for: tab) { state in
            state.isLoadingDirectory = true
            state.error = nil
            state.viewerError = nil
            state.viewerPayload = nil
            state.selectedEntryPath = nil
            state.isLoadingViewer = false
        }
        viewerRequestIDs.removeValue(forKey: tab.id)

        do {
            let snapshot = try await directorySnapshot(path: normalizedPath, for: server)
            guard isCurrentDirectoryLoadRequest(requestID, for: tab.id) else { return }
            applyDirectorySnapshot(snapshot, to: tab)
        } catch {
            guard isCurrentDirectoryLoadRequest(requestID, for: tab.id) else { return }
            logger.error("Directory load failed for \(normalizedPath, privacy: .public): \(error.localizedDescription, privacy: .public)")
            updateState(for: tab) { state in
                state.isLoadingDirectory = false
                state.error = RemoteFileBrowserError.map(error)
            }
        }
    }

    func resolveInitialDirectorySnapshot(
        for server: Server,
        tab: RemoteFileTab,
        initialPath: String?
    ) async throws -> DirectorySnapshot {
        for path in initialDirectoryCandidates(for: server, tab: tab, initialPath: initialPath) {
            do {
                return try await directorySnapshot(path: path, for: server)
            } catch {
                logger.debug("Skipping initial browser path \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        let homePath = try await withRemoteFileService(for: server) { service in
            try await service.resolveHomeDirectory()
        }
        return try await directorySnapshot(path: homePath, for: server)
    }

    func initialDirectoryCandidates(
        for server: Server,
        tab: RemoteFileTab,
        initialPath: String?
    ) -> [String] {
        let persistedPath = persistedState(for: tab.id).lastVisitedPath
        let workingDirectory = bestWorkingDirectory(for: server.id)
        var seenPaths = Set<String>()

        return [
            persistedPath,
            tab.lastKnownPath,
            initialPath,
            tab.seedPath,
            workingDirectory
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .map { RemoteFilePath.normalize($0) }
        .filter { seenPaths.insert($0).inserted }
    }

    private func directorySnapshot(path: String, for server: Server) async throws -> DirectorySnapshot {
        let normalizedPath = RemoteFilePath.normalize(path)
        let entries = try await withRemoteFileService(for: server) { service in
            try await service.listDirectory(at: normalizedPath, maxEntries: Self.directoryEntryLimit)
        }
        try Task.checkCancellation()
        let filesystemStatus = try? await withRemoteFileService(for: server) { service in
            try await service.fileSystemStatus(at: normalizedPath)
        }
        return DirectorySnapshot(
            path: normalizedPath,
            entries: entries,
            isTruncated: entries.count >= Self.directoryEntryLimit,
            filesystemStatus: filesystemStatus
        )
    }

    private func isCurrentDirectoryLoadRequest(_ requestID: UUID, for tabId: UUID) -> Bool {
        directoryLoadCoordinator.isCurrent(requestID, for: tabId)
    }

    func applyDirectorySnapshot(_ snapshot: DirectorySnapshot, to tab: RemoteFileTab) {
        updateState(for: tab) { state in
            state.currentPath = snapshot.path
            state.entries = snapshot.entries
            state.hasLoadedDirectory = true
            state.isDirectoryTruncated = snapshot.isTruncated
            state.filesystemStatus = snapshot.filesystemStatus
            state.isLoadingDirectory = false
            state.error = nil
        }
        persistState(for: tab.id)
    }

    func selectFile(_ entry: RemoteFileEntry, in tab: RemoteFileTab) {
        focus(entry, in: tab)
    }
}
