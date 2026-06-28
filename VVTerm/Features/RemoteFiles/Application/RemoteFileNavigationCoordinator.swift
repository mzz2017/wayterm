import Foundation

enum RemoteFileNavigationAction: Sendable {
    case loadInitialPath(initialPath: String?)
    case refresh
    case goUp
    case openBreadcrumb(RemoteFileBreadcrumb)
    case openDirectory(RemoteFileEntry)
    case activate(RemoteFileEntry)
}

enum RemoteFileNavigationResult: Equatable, Sendable {
    case loadedDirectory(String)
    case selectedFile(RemoteFileEntry)
    case skipped
}

extension RemoteFileBrowserStore {
    @discardableResult
    func requestNavigation(
        _ action: RemoteFileNavigationAction,
        in tab: RemoteFileTab,
        server: Server,
        onCompleted: @escaping @MainActor (RemoteFileNavigationResult) -> Void = { _ in }
    ) -> UUID {
        navigationRequestCoordinator.requestNavigation(
            in: tab,
            server: server,
            onCancelPrevious: { [weak self] tabId in
                self?.resetCancelledNavigationState(for: tabId)
            },
            perform: { [weak self] requestID in
                guard let self else { return .skipped }
                return await self.performNavigation(
                    action,
                    in: tab,
                    server: server,
                    requestID: requestID
                )
            },
            onCompleted: onCompleted
        )
    }

    @discardableResult
    func cancelNavigationRequest(for tabId: UUID) -> Task<Void, Never>? {
        guard let task = navigationRequestCoordinator.cancelRequest(for: tabId) else { return nil }
        resetCancelledNavigationState(for: tabId)
        return task
    }

    private func resetCancelledNavigationState(for tabId: UUID) {
        directoryRequestIDs.removeValue(forKey: tabId)

        guard let state = states[tabId] else { return }
        updateState(for: tabId, serverId: state.serverId) { state in
            state.isLoadingDirectory = false
        }
    }

    private func performNavigation(
        _ action: RemoteFileNavigationAction,
        in tab: RemoteFileTab,
        server: Server,
        requestID: UUID
    ) async -> RemoteFileNavigationResult {
        switch action {
        case .loadInitialPath(let initialPath):
            await loadInitialPath(for: server, tab: tab, initialPath: initialPath)
            return loadedDirectoryResult(for: tab)

        case .refresh:
            await refresh(server: server, tab: tab)
            return loadedDirectoryResult(for: tab)

        case .goUp:
            let currentPath = currentPath(for: tab)
            let parentPath = RemoteFilePath.parent(of: currentPath)
            guard parentPath != currentPath else { return .skipped }
            await loadDirectory(path: parentPath, in: tab, server: server)
            return loadedDirectoryResult(for: tab, expectedPath: parentPath)

        case .openBreadcrumb(let breadcrumb):
            await loadDirectory(path: breadcrumb.path, in: tab, server: server)
            return loadedDirectoryResult(for: tab, expectedPath: breadcrumb.path)

        case .openDirectory(let entry):
            await loadDirectory(path: entry.path, in: tab, server: server)
            return loadedDirectoryResult(for: tab, expectedPath: entry.path)

        case .activate(let entry):
            return await activateForNavigationResult(
                entry,
                in: tab,
                server: server,
                requestID: requestID
            )
        }
    }

    private func activateForNavigationResult(
        _ entry: RemoteFileEntry,
        in tab: RemoteFileTab,
        server: Server,
        requestID: UUID
    ) async -> RemoteFileNavigationResult {
        switch entry.type {
        case .directory:
            guard isCurrentNavigationRequest(requestID, for: tab.id) else { return .skipped }
            await loadDirectory(path: entry.path, in: tab, server: server)
            return loadedDirectoryResult(for: tab, expectedPath: entry.path)

        case .symlink:
            do {
                let resolvedEntry = try await withRemoteFileService(for: server) { service in
                    try await service.stat(at: entry.path)
                }
                guard isCurrentNavigationRequest(requestID, for: tab.id) else { return .skipped }
                if resolvedEntry.type == .directory {
                    await loadDirectory(path: entry.path, in: tab, server: server)
                    return loadedDirectoryResult(for: tab, expectedPath: entry.path)
                }
                selectFile(entry, in: tab)
                return .selectedFile(entry)
            } catch {
                guard isCurrentNavigationRequest(requestID, for: tab.id) else { return .skipped }
                selectFile(entry, in: tab)
                return .selectedFile(entry)
            }

        case .file, .other:
            guard isCurrentNavigationRequest(requestID, for: tab.id) else { return .skipped }
            selectFile(entry, in: tab)
            return .selectedFile(entry)
        }
    }

    private func isCurrentNavigationRequest(_ requestID: UUID, for tabId: UUID) -> Bool {
        navigationRequestCoordinator.isCurrentRequest(requestID, for: tabId)
    }

    private func loadedDirectoryResult(
        for tab: RemoteFileTab,
        expectedPath: String? = nil
    ) -> RemoteFileNavigationResult {
        guard let currentPath = currentPathValue(for: tab) else { return .skipped }
        if let expectedPath, currentPath != RemoteFilePath.normalize(expectedPath) {
            return .skipped
        }
        return .loadedDirectory(currentPath)
    }
}
