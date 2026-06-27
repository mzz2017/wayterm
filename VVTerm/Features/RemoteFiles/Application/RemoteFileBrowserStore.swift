import Combine
import Foundation
import os.log

@MainActor
final class RemoteFileBrowserStore: ObservableObject {
    typealias ServerProvider = @MainActor (UUID) -> Server?
    typealias WorkingDirectoryProvider = @MainActor (UUID) -> String?

    enum ToolbarCommandAction: Sendable {
        case upload(destinationPath: String)
        case createFolder(destinationPath: String)
    }

    struct ToolbarCommand: Identifiable, Sendable {
        let id = UUID()
        let serverId: UUID
        let tabId: UUID
        let action: ToolbarCommandAction
    }

    struct TransferProgress: Sendable {
        let completedUnitCount: Int
        let totalUnitCount: Int
        let currentItemName: String
    }

    typealias LocalUploadPlanItem = RemoteFileLocalUploadPlanItem

    struct LocalUploadPlanCandidate: Identifiable, Sendable {
        let sourceURL: URL
        let originalName: String
        let existingEntry: RemoteFileEntry?
        let suggestedName: String?

        var id: String {
            "\(sourceURL.absoluteString)->\(originalName)"
        }

        var hasConflict: Bool {
            existingEntry != nil
        }
    }

    struct BrowserState: Sendable {
        let serverId: UUID
        var currentPath: String?
        var entries: [RemoteFileEntry]
        var sort: RemoteFileSort
        var sortDirection: RemoteFileSortDirection
        var showHiddenFiles: Bool
        var hasCustomizedHiddenFiles: Bool
        var hasLoadedDirectory: Bool
        var isLoadingDirectory: Bool
        var isLoadingViewer: Bool
        var isDirectoryTruncated: Bool
        var filesystemStatus: RemoteFileFilesystemStatus?
        var error: RemoteFileBrowserError?
        var viewerError: RemoteFileBrowserError?
        var viewerPayload: RemoteFileViewerPayload?
        var selectedEntryPath: String?

        init(serverId: UUID, persisted: RemoteFileBrowserPersistedState) {
            self.serverId = serverId
            currentPath = persisted.lastVisitedPath.map { RemoteFilePath.normalize($0) }
            entries = []
            sort = persisted.sort
            sortDirection = persisted.sortDirection
            showHiddenFiles = persisted.showHiddenFiles
            hasCustomizedHiddenFiles = persisted.hasCustomizedHiddenFiles
            hasLoadedDirectory = false
            isLoadingDirectory = false
            isLoadingViewer = false
            isDirectoryTruncated = false
            filesystemStatus = nil
            error = nil
            viewerError = nil
            viewerPayload = nil
            selectedEntryPath = nil
        }

        var breadcrumbs: [RemoteFileBreadcrumb] {
            guard let currentPath else { return [] }
            return RemoteFilePath.breadcrumbs(for: currentPath)
        }
    }

    struct DirectorySnapshot: Sendable {
        let path: String
        let entries: [RemoteFileEntry]
        let isTruncated: Bool
        let filesystemStatus: RemoteFileFilesystemStatus?
    }

    struct PreviewLoadRequest {
        let entryPath: String
        let allowLargeDownloads: Bool
        let task: Task<Void, Never>
    }

    struct NavigationRequest {
        let tabId: UUID
        let serverId: UUID
        let task: Task<Void, Never>
    }

    private struct MoveDestinationLoadRequest {
        let key: MoveDestinationLoadRequestKey
        var task: Task<Void, Never>?
        var onCompleted: [@MainActor (Result<[RemoteFileEntry], Error>) -> Void]
    }

    private struct MoveDestinationLoadRequestKey: Hashable {
        let serverId: UUID
        let path: String
    }

    @Published private(set) var states: [UUID: BrowserState] = [:]
    @Published var pendingToolbarCommand: ToolbarCommand?

    let defaults: UserDefaults
    let persistenceKey = "remoteFileBrowserState.v2"
    let legacyPersistenceKey = "remoteFileBrowserState.v1"
    let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VVTerm", category: "RemoteFiles")
    nonisolated let temporaryStorage: RemoteFileTemporaryStorage
    let previewLoader: RemoteFilePreviewLoader
    let conflictResolver: RemoteFileConflictResolver
    let transferPolicy: RemoteFileTransferPolicy
    let serverProvider: ServerProvider
    let workingDirectoryProvider: WorkingDirectoryProvider
    private let serviceAccessCoordinator: RemoteFileServiceAccessCoordinator
    private let requestLifecycleCoordinator = RemoteFileRequestLifecycleCoordinator()

    var persistedStates: [String: RemoteFileBrowserPersistedState] = [:]
    var directoryRequestIDs: [UUID: UUID] = [:]
    var viewerRequestIDs: [UUID: UUID] = [:]
    var previewLoadRequests: [UUID: PreviewLoadRequest] = [:]
    var previewLoadRequestByTab: [UUID: UUID] = [:]
    var navigationRequests: [UUID: NavigationRequest] = [:]
    var navigationRequestByTab: [UUID: UUID] = [:]
    private var moveDestinationLoadRequests: [UUID: MoveDestinationLoadRequest] = [:]
    private var moveDestinationLoadRequestByKey: [MoveDestinationLoadRequestKey: UUID] = [:]

    static let directoryEntryLimit = 2_000
    static let defaultPreviewBytes = 512 * 1_024
    static let hardPreviewBytes = 2 * 1_024 * 1_024
    static let previewConfirmationBytes = 1 * 1_024 * 1_024
    static let maxMediaPreviewBytes = 64 * 1_024 * 1_024

    var pendingMutationRequestIDs: Set<UUID> {
        requestLifecycleCoordinator.pendingMutationRequestIDs
    }

    var pendingTransferRequestIDs: Set<UUID> {
        requestLifecycleCoordinator.pendingTransferRequestIDs
    }

    var pendingPreviewLoadRequestIDs: Set<UUID> {
        Set(previewLoadRequestByTab.values)
    }

    var pendingNavigationRequestIDs: Set<UUID> {
        Set(navigationRequestByTab.values)
    }

    var pendingMoveDestinationLoadRequestIDs: Set<UUID> {
        Set(moveDestinationLoadRequestByKey.values)
    }

    init(
        defaults: UserDefaults = .standard,
        remoteFileServiceAdapter: SSHSFTPAdapter? = nil,
        serviceAccessCoordinator: RemoteFileServiceAccessCoordinator? = nil,
        temporaryStorage: RemoteFileTemporaryStorage = RemoteFileTemporaryStorage(),
        previewLoader: RemoteFilePreviewLoader = RemoteFilePreviewLoader(),
        conflictResolver: RemoteFileConflictResolver = RemoteFileConflictResolver(),
        transferPolicy: RemoteFileTransferPolicy = RemoteFileTransferPolicy(),
        serverProvider: @escaping ServerProvider,
        workingDirectoryProvider: @escaping WorkingDirectoryProvider = { _ in nil }
    ) {
        self.defaults = defaults
        self.serviceAccessCoordinator = serviceAccessCoordinator ?? RemoteFileServiceAccessCoordinator(
            remoteFileServiceAdapter: remoteFileServiceAdapter ?? SSHSFTPAdapter(
                credentialsProvider: { _ in
                    throw RemoteFileBrowserStoreDependencyError.missingCredentialsProvider
                }
            )
        )
        self.temporaryStorage = temporaryStorage
        self.previewLoader = previewLoader
        self.conflictResolver = conflictResolver
        self.transferPolicy = transferPolicy
        self.serverProvider = serverProvider
        self.workingDirectoryProvider = workingDirectoryProvider
        loadPersistedStates()
    }

    func prepareNewTab(_ tab: RemoteFileTab, duplicating sourceTab: RemoteFileTab?) {
        if let sourceTab {
            let sourceState = state(for: sourceTab)
            let sourcePersistedState = persistedState(for: sourceTab.id)
            let sourcePath = sourceState.currentPath
                ?? sourcePersistedState.lastVisitedPath
                ?? sourceTab.lastKnownPath
                ?? sourceTab.seedPath

            persistedStates[tab.id.uuidString] = RemoteFileBrowserPersistedState(
                lastVisitedPath: sourcePath,
                sort: sourceState.sort,
                sortDirection: sourceState.sortDirection,
                showHiddenFiles: sourceState.showHiddenFiles,
                hasCustomizedHiddenFiles: sourceState.hasCustomizedHiddenFiles
            )
            states[tab.id] = BrowserState(serverId: tab.serverId, persisted: persistedState(for: tab.id))
            persistStates()
            return
        }

        guard persistedStates[tab.id.uuidString] == nil else { return }
        persistedStates[tab.id.uuidString] = RemoteFileBrowserPersistedState(
            lastVisitedPath: tab.seedPath ?? tab.lastKnownPath
        )
        persistStates()
    }

    func state(for tab: RemoteFileTab) -> BrowserState {
        states[tab.id] ?? BrowserState(serverId: tab.serverId, persisted: persistedState(for: tab.id))
    }

    @discardableResult
    func requestMutation(
        serverId: UUID? = nil,
        operation: @escaping @MainActor () async throws -> Void,
        onSuccess: @escaping @MainActor () -> Void = {},
        onFailure: @escaping @MainActor (Error) -> Void = { _ in }
    ) -> UUID {
        requestMutation(
            serverId: serverId,
            operation: {
                try await operation()
                return ()
            },
            onSuccess: { _ in
                onSuccess()
            },
            onFailure: onFailure
        )
    }

    @discardableResult
    func requestMutation<Result>(
        serverId: UUID? = nil,
        operation: @escaping @MainActor () async throws -> Result,
        onSuccess: @escaping @MainActor (Result) -> Void,
        onFailure: @escaping @MainActor (Error) -> Void = { _ in }
    ) -> UUID {
        requestLifecycleCoordinator.requestMutation(
            serverId: serverId,
            operation: operation,
            onSuccess: onSuccess,
            onFailure: onFailure
        )
    }

    func waitForMutationRequest(_ requestID: UUID) async {
        await requestLifecycleCoordinator.waitForMutationRequest(requestID)
    }

    @discardableResult
    func requestTransfer<Result>(
        serverId: UUID? = nil,
        operation: @escaping @MainActor @Sendable (@escaping @MainActor @Sendable (TransferProgress) -> Void) async throws -> Result,
        onProgress: @escaping @MainActor @Sendable (TransferProgress) -> Void = { _ in },
        onSuccess: @escaping @MainActor @Sendable (Result) -> Void,
        onFailure: @escaping @MainActor @Sendable (Error) -> Void = { _ in }
    ) -> UUID {
        requestLifecycleCoordinator.requestTransfer(
            serverId: serverId,
            operation: operation,
            onProgress: onProgress,
            onSuccess: onSuccess,
            onFailure: onFailure
        )
    }

    func waitForTransferRequest(_ requestID: UUID) async {
        await requestLifecycleCoordinator.waitForTransferRequest(requestID)
    }

    func waitForPreviewLoadRequest(_ requestID: UUID) async {
        await previewLoadRequests[requestID]?.task.value
    }

    func waitForNavigationRequest(_ requestID: UUID) async {
        await navigationRequests[requestID]?.task.value
    }

    func waitForMoveDestinationLoadRequest(_ requestID: UUID) async {
        await moveDestinationLoadRequests[requestID]?.task?.value
    }

    @discardableResult
    func requestMoveDestinationLoad(
        path: String,
        server: Server,
        onCompleted: @escaping @MainActor (Result<[RemoteFileEntry], Error>) -> Void
    ) -> UUID {
        let normalizedPath = RemoteFilePath.normalize(path)
        let key = MoveDestinationLoadRequestKey(serverId: server.id, path: normalizedPath)

        if let requestID = moveDestinationLoadRequestByKey[key] {
            moveDestinationLoadRequests[requestID]?.onCompleted.append(onCompleted)
            return requestID
        }

        let requestID = UUID()
        moveDestinationLoadRequests[requestID] = MoveDestinationLoadRequest(
            key: key,
            task: nil,
            onCompleted: [onCompleted]
        )
        moveDestinationLoadRequestByKey[key] = requestID

        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                self.moveDestinationLoadRequests.removeValue(forKey: requestID)
                if self.moveDestinationLoadRequestByKey[key] == requestID {
                    self.moveDestinationLoadRequestByKey.removeValue(forKey: key)
                }
            }

            let result: Result<[RemoteFileEntry], Error>
            do {
                let entries = try await self.listDirectories(at: normalizedPath, server: server)
                result = .success(entries)
            } catch {
                result = .failure(error)
            }

            guard !Task.isCancelled else { return }
            guard self.moveDestinationLoadRequestByKey[key] == requestID else { return }

            let callbacks = self.moveDestinationLoadRequests[requestID]?.onCompleted ?? []
            callbacks.forEach { $0(result) }
        }

        if moveDestinationLoadRequests[requestID]?.key == key {
            moveDestinationLoadRequests[requestID]?.task = task
        }

        return requestID
    }

    func currentPathValue(for tab: RemoteFileTab) -> String? {
        state(for: tab).currentPath
    }

    func lastVisitedPath(for tab: RemoteFileTab) -> String? {
        state(for: tab).currentPath
            ?? persistedState(for: tab.id).lastVisitedPath
            ?? tab.lastKnownPath
            ?? tab.seedPath
    }

    func currentPath(for tab: RemoteFileTab) -> String {
        lastVisitedPath(for: tab) ?? "/"
    }

    func displayedEntries(for tab: RemoteFileTab) -> [RemoteFileEntry] {
        let state = state(for: tab)
        let visibleEntries = state.showHiddenFiles
            ? state.entries
            : state.entries.filter { !$0.isHidden }
        return visibleEntries.sortedForBrowser(using: state.sort, direction: state.sortDirection)
    }

    func entries(for tab: RemoteFileTab) -> [RemoteFileEntry] {
        displayedEntries(for: tab)
    }

    func selectedEntryPath(for tab: RemoteFileTab) -> String? {
        state(for: tab).selectedEntryPath
    }

    func viewerPayload(for tab: RemoteFileTab) -> RemoteFileViewerPayload? {
        state(for: tab).viewerPayload
    }

    func error(for tab: RemoteFileTab) -> RemoteFileBrowserError? {
        state(for: tab).error
    }

    func viewerError(for tab: RemoteFileTab) -> RemoteFileBrowserError? {
        state(for: tab).viewerError
    }

    func isLoading(for tab: RemoteFileTab) -> Bool {
        state(for: tab).isLoadingDirectory
    }

    func isLoadingViewer(for tab: RemoteFileTab) -> Bool {
        state(for: tab).isLoadingViewer
    }

    func isTruncated(for tab: RemoteFileTab) -> Bool {
        state(for: tab).isDirectoryTruncated
    }

    func filesystemStatus(for tab: RemoteFileTab) -> RemoteFileFilesystemStatus? {
        state(for: tab).filesystemStatus
    }

    func sort(for tab: RemoteFileTab) -> RemoteFileSort {
        state(for: tab).sort
    }

    func sortDirection(for tab: RemoteFileTab) -> RemoteFileSortDirection {
        state(for: tab).sortDirection
    }

    func showHiddenFiles(for tab: RemoteFileTab) -> Bool {
        state(for: tab).showHiddenFiles
    }

    func breadcrumbs(for tab: RemoteFileTab) -> [RemoteFileBreadcrumb] {
        state(for: tab).breadcrumbs
    }

    func focus(_ entry: RemoteFileEntry, in tab: RemoteFileTab) {
        cancelPreviewLoadRequest(for: tab.id)
        viewerRequestIDs[tab.id] = UUID()
        cleanupPreviewArtifact(for: state(for: tab).viewerPayload)
        updateState(for: tab) { state in
            state.selectedEntryPath = entry.path
            state.viewerPayload = nil
            state.viewerError = nil
            state.isLoadingViewer = false
        }
    }

    func updateSort(_ sort: RemoteFileSort, for tab: RemoteFileTab) {
        updateSort(sort, direction: sort.defaultDirection, for: tab)
    }

    func updateSort(_ sort: RemoteFileSort, direction: RemoteFileSortDirection, for tab: RemoteFileTab) {
        updateState(for: tab) { state in
            state.sort = sort
            state.sortDirection = direction
        }
        persistState(for: tab.id)
    }

    func setShowHiddenFiles(_ showHiddenFiles: Bool, for tab: RemoteFileTab) {
        updateState(for: tab) { state in
            state.showHiddenFiles = showHiddenFiles
            state.hasCustomizedHiddenFiles = true
        }
        persistState(for: tab.id)
    }

    func removeState(for tabId: UUID) {
        removeRuntimeState(for: tabId)
        persistedStates.removeValue(forKey: tabId.uuidString)
        persistStates()
    }

    func removeRuntimeState(for tabId: UUID) {
        cancelNavigationRequest(for: tabId)
        cancelPreviewLoadRequest(for: tabId)
        directoryRequestIDs.removeValue(forKey: tabId)
        viewerRequestIDs.removeValue(forKey: tabId)
        temporaryStorage.removePreviewArtifact(for: states[tabId]?.viewerPayload)
        states.removeValue(forKey: tabId)

        if pendingToolbarCommand?.tabId == tabId {
            pendingToolbarCommand = nil
        }
    }

    @discardableResult
    func disconnect(serverId: UUID) -> Task<Void, Never> {
        cancelMutationRequests(for: serverId)
        cancelTransferRequests(for: serverId)
        cancelMoveDestinationLoadRequests(for: serverId)

        var affectedTabIDs = Set(
            states.compactMap { tabId, state in
                state.serverId == serverId ? tabId : nil
            }
        )
        affectedTabIDs.formUnion(
            navigationRequests.values.compactMap { request in
                request.serverId == serverId ? request.tabId : nil
            }
        )

        for tabId in affectedTabIDs {
            removeRuntimeState(for: tabId)
        }

        return serviceAccessCoordinator.disconnect(serverId: serverId)
    }

    func cancelPreviewLoadRequest(for tabId: UUID) {
        guard let requestID = previewLoadRequestByTab.removeValue(forKey: tabId) else { return }
        viewerRequestIDs.removeValue(forKey: tabId)
        previewLoadRequests[requestID]?.task.cancel()
    }

    func cancelMutationRequests(for serverId: UUID) {
        requestLifecycleCoordinator.cancelMutationRequests(for: serverId)
    }

    func cancelTransferRequests(for serverId: UUID) {
        requestLifecycleCoordinator.cancelTransferRequests(for: serverId)
    }

    private func cancelMoveDestinationLoadRequests(for serverId: UUID) {
        for (requestID, request) in moveDestinationLoadRequests where request.key.serverId == serverId {
            if moveDestinationLoadRequestByKey[request.key] == requestID {
                moveDestinationLoadRequestByKey.removeValue(forKey: request.key)
            }
            request.task?.cancel()
        }
    }

    func withRemoteFileService<T>(
        for server: Server,
        operation: @escaping (any RemoteFileService) async throws -> T
    ) async throws -> T {
        try await serviceAccessCoordinator.withRemoteFileService(for: server, operation: operation)
    }

    #if DEBUG
    func setPendingDisconnectWaitDidFinishForTesting(
        _ action: (@MainActor (UUID) async -> Void)?
    ) {
        serviceAccessCoordinator.setPendingDisconnectWaitDidFinishForTesting(action)
    }

    func cancelMoveDestinationLoadRequestForTesting(_ requestID: UUID) {
        guard let request = moveDestinationLoadRequests[requestID] else { return }
        if moveDestinationLoadRequestByKey[request.key] == requestID {
            moveDestinationLoadRequestByKey.removeValue(forKey: request.key)
        }
        moveDestinationLoadRequests[requestID]?.task?.cancel()
    }
    #endif

    func bestWorkingDirectory(for serverId: UUID) -> String? {
        workingDirectoryProvider(serverId)
    }

    func updateState(for tab: RemoteFileTab, mutation: (inout BrowserState) -> Void) {
        updateState(for: tab.id, serverId: tab.serverId, mutation: mutation)
    }

    func updateState(for tabId: UUID, serverId: UUID, mutation: (inout BrowserState) -> Void) {
        var state = states[tabId] ?? BrowserState(serverId: serverId, persisted: persistedState(for: tabId))
        mutation(&state)
        states[tabId] = state
    }

    func server(for serverId: UUID) -> Server? {
        serverProvider(serverId)
    }

    func setPendingToolbarCommand(_ command: ToolbarCommand?) {
        pendingToolbarCommand = command
    }
}

private enum RemoteFileBrowserStoreDependencyError: LocalizedError {
    case missingCredentialsProvider

    var errorDescription: String? {
        "Remote file credentials provider was not configured."
    }
}

extension String {
    var nonEmptyString: String? {
        isEmpty ? nil : self
    }
}
