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

    @Published private(set) var states: [UUID: BrowserState] = [:]
    @Published var pendingToolbarCommand: ToolbarCommand?

    let persistedStateStore: RemoteFileBrowserPersistedStateStore
    let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VVTerm", category: "RemoteFiles")
    nonisolated let temporaryStorage: RemoteFileTemporaryStorage
    nonisolated let localFileService: RemoteFileLocalFileService
    let previewLoader: RemoteFilePreviewLoader
    let conflictResolver: RemoteFileConflictResolver
    let transferPolicy: RemoteFileTransferPolicy
    let serverProvider: ServerProvider
    let workingDirectoryProvider: WorkingDirectoryProvider
    private let serviceAccessCoordinator: RemoteFileServiceAccessCoordinator
    private let requestLifecycleCoordinator = RemoteFileRequestLifecycleCoordinator()
    let previewLoadCoordinator = RemoteFilePreviewLoadCoordinator()
    let navigationRequestCoordinator = RemoteFileNavigationRequestCoordinator()
    private let moveDestinationLoadCoordinator = RemoteFileMoveDestinationLoadCoordinator()

    var persistedStates: [String: RemoteFileBrowserPersistedState] = [:]
    var directoryRequestIDs: [UUID: UUID] = [:]
    var viewerRequestIDs: [UUID: UUID] = [:]
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
        previewLoadCoordinator.pendingRequestIDs
    }

    var pendingNavigationRequestIDs: Set<UUID> {
        navigationRequestCoordinator.pendingRequestIDs
    }

    var pendingMoveDestinationLoadRequestIDs: Set<UUID> {
        moveDestinationLoadCoordinator.pendingRequestIDs
    }

    init(
        persistedStateStore: RemoteFileBrowserPersistedStateStore? = nil,
        remoteFileServiceAdapter: SSHSFTPAdapter? = nil,
        serviceAccessCoordinator: RemoteFileServiceAccessCoordinator? = nil,
        temporaryStorage: RemoteFileTemporaryStorage = RemoteFileTemporaryStorage(),
        localFileService: RemoteFileLocalFileService = RemoteFileLocalFileService(),
        previewLoader: RemoteFilePreviewLoader = RemoteFilePreviewLoader(),
        conflictResolver: RemoteFileConflictResolver = RemoteFileConflictResolver(),
        transferPolicy: RemoteFileTransferPolicy = RemoteFileTransferPolicy(),
        serverProvider: @escaping ServerProvider,
        workingDirectoryProvider: @escaping WorkingDirectoryProvider = { _ in nil }
    ) {
        self.persistedStateStore = persistedStateStore ?? RemoteFileBrowserPersistedStateStore()
        self.serviceAccessCoordinator = serviceAccessCoordinator ?? RemoteFileServiceAccessCoordinator(
            remoteFileServiceAdapter: remoteFileServiceAdapter ?? SSHSFTPAdapter(
                credentialsProvider: { _ in
                    throw RemoteFileBrowserStoreDependencyError.missingCredentialsProvider
                }
            )
        )
        self.temporaryStorage = temporaryStorage
        self.localFileService = localFileService
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
        await previewLoadCoordinator.waitForRequest(requestID)
    }

    func waitForNavigationRequest(_ requestID: UUID) async {
        await navigationRequestCoordinator.waitForRequest(requestID)
    }

    func waitForMoveDestinationLoadRequest(_ requestID: UUID) async {
        await moveDestinationLoadCoordinator.waitForRequest(requestID)
    }

    @discardableResult
    func requestMoveDestinationLoad(
        path: String,
        server: Server,
        onCompleted: @escaping @MainActor (Result<[RemoteFileEntry], Error>) -> Void
    ) -> UUID {
        moveDestinationLoadCoordinator.requestLoad(
            path: path,
            server: server,
            loadDirectories: { [weak self] path, server in
                guard let self else { throw RemoteFileBrowserError.disconnected }
                return try await self.listDirectories(at: path, server: server)
            },
            onCompleted: onCompleted
        )
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
            navigationRequestCoordinator.affectedTabIDs(for: serverId)
        )

        for tabId in affectedTabIDs {
            removeRuntimeState(for: tabId)
        }

        return serviceAccessCoordinator.disconnect(serverId: serverId)
    }

    func cancelPreviewLoadRequest(for tabId: UUID) {
        viewerRequestIDs.removeValue(forKey: tabId)
        previewLoadCoordinator.cancelRequest(for: tabId)
    }

    func cancelMutationRequests(for serverId: UUID) {
        requestLifecycleCoordinator.cancelMutationRequests(for: serverId)
    }

    func cancelTransferRequests(for serverId: UUID) {
        requestLifecycleCoordinator.cancelTransferRequests(for: serverId)
    }

    private func cancelMoveDestinationLoadRequests(for serverId: UUID) {
        moveDestinationLoadCoordinator.cancelRequests(for: serverId)
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
        moveDestinationLoadCoordinator.cancelRequest(requestID)
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
