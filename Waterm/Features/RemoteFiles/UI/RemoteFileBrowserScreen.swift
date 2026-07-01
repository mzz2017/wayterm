import SwiftUI
import UniformTypeIdentifiers

struct RemoteFileBrowserScreen: View {
    @ObservedObject var browser: RemoteFileBrowserStore
    let server: Server
    let fileTab: RemoteFileTab
    let initialPath: String?
    let onCurrentPathChange: @MainActor (String?) -> Void

    @Environment(\.colorScheme) var colorScheme
    @AppStorage(CloudKitSyncConstants.terminalThemeNameKey) var terminalThemeName = "Aizen Dark"
    @AppStorage(CloudKitSyncConstants.terminalThemeNameLightKey) var terminalThemeNameLight = "Aizen Light"
    @AppStorage(CloudKitSyncConstants.terminalUsePerAppearanceThemeKey) var usePerAppearanceTheme = true
    @State var presentedPreviewPath: String?
    @State var uploadDestinationPath: String?
    @State var uploadImportRequest: UploadImportRequest?
    @State var downloadExportDocument: RemoteFileDownloadDocument?
    @State var downloadExportFilename = ""
    @State var isDownloadExporterPresented = false
    @State var shareItem: RemoteFileShareItem?
    @State var iOSSearchQuery = ""
    @State var newFolderDestinationPath: String?
    @State var newFolderName = ""
    @State var isCreateFolderSubmitting = false
    @State var renameTargetEntry: RemoteFileEntry?
    @State var renameName = ""
    @State var isRenameSubmitting = false
    @State var moveTargetEntry: RemoteFileEntry?
    @State var moveDestinationDirectory = ""
    @State var isMoveSubmitting = false
    @State var deleteTargetEntry: RemoteFileEntry?
    @State var permissionTargetEntry: RemoteFileEntry?
    @State var permissionDraft = RemoteFilePermissionDraft(accessBits: 0)
    @State var permissionEditContext: RemoteFilePermissionEditContext?
    @State var isPermissionSubmitting = false
    @State var permissionErrorMessage: String?
    @State var operationErrorMessage: String?
    @State var isDropTargeted = false
    @StateObject private var noticeHost = NoticeHostModel()
    #if os(macOS)
    @State var macOSInlineEditor: MacOSInlineEditor?
    @State var macOSSelectedPaths: Set<String> = []
    @State var macOSTitlebarHeight: CGFloat = 0
    #endif

    struct Snapshot {
        let currentPath: String
        let breadcrumbs: [RemoteFileBreadcrumb]
        let entries: [RemoteFileEntry]
        let selectedEntry: RemoteFileEntry?
        let viewerPayload: RemoteFileViewerPayload?
        let directoryError: RemoteFileBrowserError?
        let viewerError: RemoteFileBrowserError?
        let isLoadingDirectory: Bool
        let isLoadingViewer: Bool
        let sort: RemoteFileSort
        let sortDirection: RemoteFileSortDirection
        let showHiddenFiles: Bool
        let isTruncated: Bool
        let selectedPath: String?
        let filesystemStatus: RemoteFileFilesystemStatus?
    }

    struct EmptyStateContent {
        let icon: String
        let title: String
        let message: String
    }

    struct UploadImportRequest: Identifiable {
        let id = UUID()
        let destinationPath: String
    }

    #if os(macOS)
    enum MacOSInlineEditor: Equatable {
        case createFolder(parentPath: String, proposedName: String, isSubmitting: Bool)
        case rename(entryPath: String, originalName: String, proposedName: String, isSubmitting: Bool)

        var proposedName: String {
            switch self {
            case .createFolder(_, let proposedName, _),
                 .rename(_, _, let proposedName, _):
                return proposedName
            }
        }

        var isSubmitting: Bool {
            switch self {
            case .createFolder(_, _, let isSubmitting),
                 .rename(_, _, _, let isSubmitting):
                return isSubmitting
            }
        }

        var createFolderParentPath: String? {
            guard case .createFolder(let parentPath, _, _) = self else { return nil }
            return parentPath
        }

        var renameEntryPath: String? {
            guard case .rename(let entryPath, _, _, _) = self else { return nil }
            return entryPath
        }
    }
    #endif

    init(
        browser: RemoteFileBrowserStore,
        server: Server,
        fileTab: RemoteFileTab,
        initialPath: String? = nil,
        onCurrentPathChange: @escaping @MainActor (String?) -> Void = { _ in }
    ) {
        self.browser = browser
        self.server = server
        self.fileTab = fileTab
        self.initialPath = initialPath
        self.onCurrentPathChange = onCurrentPathChange
    }

    var snapshot: Snapshot {
        let entries = browser.entries(for: fileTab)
        let viewerPayload = browser.viewerPayload(for: fileTab)
        let selectedPath = browser.selectedEntryPath(for: fileTab) ?? viewerPayload?.entry.path
        let selectedEntry = entries.first(where: { $0.path == selectedPath }) ?? viewerPayload?.entry

        return Snapshot(
            currentPath: browser.currentPath(for: fileTab),
            breadcrumbs: browser.breadcrumbs(for: fileTab),
            entries: entries,
            selectedEntry: selectedEntry,
            viewerPayload: viewerPayload,
            directoryError: browser.error(for: fileTab),
            viewerError: browser.viewerError(for: fileTab),
            isLoadingDirectory: browser.isLoading(for: fileTab),
            isLoadingViewer: browser.isLoadingViewer(for: fileTab),
            sort: browser.sort(for: fileTab),
            sortDirection: browser.sortDirection(for: fileTab),
            showHiddenFiles: browser.showHiddenFiles(for: fileTab),
            isTruncated: browser.isTruncated(for: fileTab),
            selectedPath: selectedPath,
            filesystemStatus: browser.filesystemStatus(for: fileTab)
        )
    }

    var initialLoadTaskID: String {
        "\(server.id.uuidString):\(fileTab.id.uuidString):\(initialPath ?? "")"
    }

    var remoteRowDropTypeIdentifiers: [String] {
        [UTType.watermRemoteFileEntry.identifier, UTType.fileURL.identifier]
    }

    var effectiveThemeName: String {
        guard usePerAppearanceTheme else { return terminalThemeName }
        return colorScheme == .dark ? terminalThemeName : terminalThemeNameLight
    }

    var terminalThemeBackgroundColor: Color {
        let fallbackHex = colorScheme == .dark ? "#000000" : "#FFFFFF"
        let resolved = TerminalThemeBackgroundResolver.resolve(
            themeName: effectiveThemeName,
            fallbackHex: fallbackHex
        )
        if !resolved.usedFallback {
            return resolved.color
        }

        if let cachedHex = UserDefaults.standard.string(forKey: TerminalThemeBackgroundResolver.cacheKey) {
            return Color.fromHex(cachedHex)
        }

        return colorScheme == .dark ? .black : .white
    }

    var operationErrorText: String {
        operationErrorMessage ?? ""
    }

    var body: some View {
        NoticeHost(
            topBanner: noticeHost.topBanner,
            bottomOperation: noticeHost.bottomOperation
        ) {
            ZStack {
                Group {
                    #if os(macOS)
                    macOSContent(snapshot)
                    #else
                    iOSContent(snapshot)
                    #endif
                }

                if isDropTargeted {
                    RemoteFileDropOverlay()
                        .padding(20)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
            }
        }
        .task(id: initialLoadTaskID) {
            browser.requestNavigation(
                .loadInitialPath(initialPath: initialPath),
                in: fileTab,
                server: server
            )
        }
        .onAppear {
            onCurrentPathChange(browser.lastVisitedPath(for: fileTab))
        }
        #if os(macOS)
        .fileImporter(
            isPresented: uploadImporterBinding,
            allowedContentTypes: [.item, .folder],
            allowsMultipleSelection: true
        ) { result in
            handleUploadSelection(result)
        }
        #else
        .sheet(item: $uploadImportRequest) { request in
            RemoteFileImportPicker { result in
                handleUploadSelection(result, for: request)
            }
        }
        #endif
        .fileExporter(
            isPresented: $isDownloadExporterPresented,
            document: downloadExportDocument,
            contentType: .data,
            defaultFilename: downloadExportFilename
        ) { result in
            handleDownloadExportCompletion(result)
        }
        #if os(iOS)
        .searchable(text: $iOSSearchQuery, prompt: String(localized: "Search Files"))
        #endif
        #if os(macOS)
        .overlay(alignment: .topTrailing) {
            if let shareItem {
                RemoteFileSharePicker(item: shareItem) {
                    finishSharing(shareItem)
                }
                .frame(width: 1, height: 1)
                .padding(.top, 12)
                .padding(.trailing, 12)
            }
        }
        #else
        .sheet(item: $shareItem) { item in
            RemoteFileShareSheet(item: item) {
                finishSharing(item)
            }
        }
        #endif
        #if os(iOS)
        .onDrop(of: remoteRowDropTypeIdentifiers, isTargeted: $isDropTargeted) { providers in
            handleCurrentDirectoryDrop(providers, to: snapshot.currentPath)
        }
        #endif
        #if os(iOS)
        .sheet(isPresented: newFolderPromptBinding, onDismiss: resetNewFolderPrompt) {
            if let destinationPath = newFolderDestinationPath {
                RemoteFileCreateFolderSheet(
                    destinationPath: destinationPath,
                    folderName: $newFolderName,
                    isSubmitting: isCreateFolderSubmitting,
                    onCancel: resetNewFolderPrompt,
                    onCreate: createFolder
                )
            }
        }
        #endif
        .alert(
            String(localized: "Files"),
            isPresented: operationErrorBinding,
            actions: { operationErrorActions },
            message: { operationErrorMessageView }
        )
        #if os(iOS)
        .sheet(item: $renameTargetEntry, onDismiss: resetRenamePrompt) { entry in
            renameSheet(entry: entry)
        }
        #endif
        .sheet(item: $moveTargetEntry, onDismiss: resetMovePrompt) { entry in
            moveSheet(entry: entry)
        }
        #if os(iOS)
        .sheet(item: $deleteTargetEntry, onDismiss: { deleteTargetEntry = nil }) { entry in
            deleteSheet(entry: entry)
        }
        #endif
        .sheet(item: $permissionTargetEntry, onDismiss: resetPermissionEditor) { entry in
            permissionSheet(entry: entry)
        }
        .onChange(of: snapshot.currentPath) { newValue in
            onCurrentPathChange(newValue)
            if let destination = newFolderDestinationPath, destination != newValue {
                resetNewFolderPrompt()
            }
            #if os(macOS)
            cancelMacOSInlineEdit()
            macOSSelectedPaths.removeAll()
            #endif
        }
        .onChange(of: browser.pendingToolbarCommand?.id) { _ in
            handlePendingToolbarCommand()
        }
        #if os(macOS)
        .onChange(of: snapshot.entries.map(\.id)) { visiblePaths in
            let nextSelection = macOSSelectedPaths.intersection(Set(visiblePaths))
            if nextSelection != macOSSelectedPaths {
                macOSSelectedPaths = nextSelection
            }

            if let inlineRenamePath = macOSInlineEditor?.renameEntryPath,
               !visiblePaths.contains(inlineRenamePath),
               macOSInlineEditor?.isSubmitting == false {
                macOSInlineEditor = nil
            }
        }
        .onChange(of: snapshot.selectedPath) { newValue in
            guard macOSSelectedPaths.count <= 1 else { return }

            guard let newValue, snapshot.entries.contains(where: { $0.id == newValue }) else {
                if !macOSSelectedPaths.isEmpty {
                    macOSSelectedPaths = []
                }
                return
            }

            if macOSSelectedPaths != [newValue] {
                macOSSelectedPaths = [newValue]
            }
        }
        #endif
    }

    var uploadImporterBinding: Binding<Bool> {
        Binding(
            get: { uploadDestinationPath != nil },
            set: { isPresented in
                if !isPresented {
                    uploadDestinationPath = nil
                }
            }
        )
    }

    var newFolderPromptBinding: Binding<Bool> {
        Binding(
            get: { newFolderDestinationPath != nil },
            set: { isPresented in
                if !isPresented {
                    resetNewFolderPrompt()
                }
            }
        )
    }

    var renamePromptBinding: Binding<Bool> {
        Binding(
            get: { renameTargetEntry != nil },
            set: { isPresented in
                if !isPresented {
                    resetRenamePrompt()
                }
            }
        )
    }

    var deletePromptBinding: Binding<Bool> {
        Binding(
            get: { deleteTargetEntry != nil },
            set: { isPresented in
                if !isPresented {
                    deleteTargetEntry = nil
                }
            }
        )
    }

    func deleteAlertMessage(for entry: RemoteFileEntry) -> String {
        let itemName = entry.name.isEmpty ? entry.path : entry.name
        return String(
            format: String(localized: "This will permanently remove \"%@\" from the remote server. This cannot be undone."),
            itemName
        )
    }

    var operationErrorBinding: Binding<Bool> {
        Binding(
            get: { operationErrorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    operationErrorMessage = nil
                }
            }
        )
    }

    func remoteOperationErrorMessage(for error: Error) -> String {
        RemoteFileBrowserError.map(error).errorDescription ?? error.localizedDescription
    }

    @MainActor
    func presentOperationError(_ error: Error) {
        operationErrorMessage = remoteOperationErrorMessage(for: error)
    }

    @MainActor
    func copyPathToClipboard(_ path: String) {
        Clipboard.copy(path)
        noticeHost.show(
            NoticeItem(
                id: UUID().uuidString,
                lane: .topBanner,
                level: .success,
                leading: .icon("checkmark.circle.fill"),
                message: String(localized: "Path copied to clipboard."),
                lifetime: .autoDismiss(.seconds(1.5))
            )
        )
    }

    @MainActor
    func showNotice(_ item: NoticeItem) {
        noticeHost.show(item)
    }

    @MainActor
    func dismissNotice(id: String) {
        noticeHost.dismiss(id: id)
    }

    @MainActor
    func bottomOperationNotice() -> NoticeItem? {
        noticeHost.bottomOperation
    }

    func performOperation(
        onFailure: (@MainActor @Sendable (Error) -> Void)? = nil,
        operation: @escaping @MainActor @Sendable () async throws -> Void
    ) {
        browser.requestMutation(
            serverId: server.id,
            operation: operation,
            onFailure: { error in
                if let onFailure {
                    onFailure(error)
                } else {
                    presentOperationError(error)
                }
            }
        )
    }

    func performOperation<Result>(
        operation: @escaping @MainActor @Sendable () async throws -> Result,
        onSuccess: @escaping @MainActor @Sendable (Result) -> Void,
        onFailure: (@MainActor @Sendable (Error) -> Void)? = nil
    ) {
        browser.requestMutation(
            serverId: server.id,
            operation: operation,
            onSuccess: onSuccess,
            onFailure: { error in
                if let onFailure {
                    onFailure(error)
                } else {
                    presentOperationError(error)
                }
            }
        )
    }

    var trimmedNewFolderName: String {
        newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var trimmedRenameName: String {
        renameName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func beginCreateFolder(in remotePath: String) {
        #if os(macOS)
        beginMacOSInlineCreateFolder(in: remotePath)
        #else
        newFolderDestinationPath = remotePath
        newFolderName = ""
        isCreateFolderSubmitting = false
        #endif
    }

    func beginRename(_ entry: RemoteFileEntry) {
        #if os(macOS)
        macOSSelectedPaths = [entry.id]
        browser.focus(entry, in: fileTab)
        macOSInlineEditor = .rename(
            entryPath: entry.path,
            originalName: entry.name,
            proposedName: entry.name,
            isSubmitting: false
        )
        #else
        renameTargetEntry = entry
        renameName = entry.name
        isRenameSubmitting = false
        #endif
    }

    func beginMove(_ entry: RemoteFileEntry) {
        moveTargetEntry = entry
        moveDestinationDirectory = RemoteFilePath.parent(of: entry.path)
        isMoveSubmitting = false
    }

    func beginEditPermissions(_ entry: RemoteFileEntry) {
        guard let context = RemoteFilePermissionEditPolicy.context(for: entry) else { return }
        permissionTargetEntry = entry
        permissionDraft = context.draft
        permissionEditContext = context
        permissionErrorMessage = nil
        isPermissionSubmitting = false
    }

    func canEditPermissions(for entry: RemoteFileEntry) -> Bool {
        RemoteFilePermissionEditPolicy.canEditPermissions(for: entry)
    }

    func previewEntry(_ entry: RemoteFileEntry) {
        browser.requestNavigation(.activate(entry), in: fileTab, server: server) { result in
            #if os(iOS)
            if result == .selectedFile(entry) {
                presentedPreviewPath = entry.path
            }
            #endif
        }
    }

    func createFolder() {
        guard let destinationPath = newFolderDestinationPath else { return }
        guard !isCreateFolderSubmitting else { return }
        guard !trimmedNewFolderName.isEmpty else {
            resetNewFolderPrompt()
            return
        }
        isCreateFolderSubmitting = true

        performOperation(
            operation: {
                let folderName = try browser.validatedRemoteName(trimmedNewFolderName)
                try await browser.createDirectory(
                    named: folderName,
                    in: destinationPath,
                    tab: fileTab,
                    server: server
                )
            },
            onSuccess: { _ in
                resetNewFolderPrompt()
            },
            onFailure: { error in
                isCreateFolderSubmitting = false
                presentOperationError(error)
            }
        )
    }

    func renameEntry() {
        guard let entry = renameTargetEntry, !isRenameSubmitting else { return }
        isRenameSubmitting = true

        performOperation(
            operation: {
                let newName = try browser.validatedRemoteName(trimmedRenameName)
                guard newName != entry.name else {
                    return false
                }

                let destinationPath = RemoteFilePath.appending(
                    newName,
                    to: RemoteFilePath.parent(of: entry.path)
                )
                try await browser.renameItem(
                    at: entry.path,
                    to: destinationPath,
                    in: fileTab,
                    server: server
                )
                return true
            },
            onSuccess: { _ in
                resetRenamePrompt()
            },
            onFailure: { error in
                isRenameSubmitting = false
                presentOperationError(error)
            }
        )
    }

    func moveEntry() {
        guard let entry = moveTargetEntry, !isMoveSubmitting else { return }
        isMoveSubmitting = true

        performOperation(
            operation: {
                let sourceDirectory = RemoteFilePath.parent(of: entry.path)
                let destinationDirectory = try browser.validatedRemoteDirectoryPath(
                    moveDestinationDirectory,
                    relativeTo: sourceDirectory
                )
                let destinationPath = RemoteFilePath.appending(entry.name, to: destinationDirectory)

                guard destinationPath != entry.path else {
                    return false
                }

                try await browser.renameItem(
                    at: entry.path,
                    to: destinationPath,
                    in: fileTab,
                    server: server
                )
                return true
            },
            onSuccess: { _ in
                resetMovePrompt()
            },
            onFailure: { error in
                isMoveSubmitting = false
                presentOperationError(error)
            }
        )
    }

    func deleteEntry() {
        guard let entry = deleteTargetEntry else { return }
        deleteTargetEntry = nil

        deleteEntries([entry])
    }

    func deleteEntries(_ entries: [RemoteFileEntry]) {
        guard !entries.isEmpty else { return }

        performOperation {
            try await browser.deleteEntries(entries, in: fileTab, server: server)
        }
    }

    func requestDelete(_ entries: [RemoteFileEntry]) {
        guard !entries.isEmpty else { return }

        #if os(macOS)
        presentMacOSDeleteConfirmation(for: entries)
        #else
        guard entries.count == 1, let entry = entries.first else { return }
        deleteTargetEntry = entry
        #endif
    }

    func resetNewFolderPrompt() {
        newFolderDestinationPath = nil
        newFolderName = ""
        isCreateFolderSubmitting = false
    }

    func resetRenamePrompt() {
        renameTargetEntry = nil
        renameName = ""
        isRenameSubmitting = false
    }

    func resetMovePrompt() {
        moveTargetEntry = nil
        moveDestinationDirectory = ""
        isMoveSubmitting = false
    }

    func applyPermissions() {
        guard let entry = permissionTargetEntry,
              let context = permissionEditContext,
              !isPermissionSubmitting else { return }
        permissionErrorMessage = nil
        isPermissionSubmitting = true

        performOperation(
            operation: {
                let requestedPermissions = RemoteFilePermissionEditPolicy.requestedPermissions(
                    draft: permissionDraft,
                    context: context
                )
                try await browser.setPermissions(entry, permissions: requestedPermissions, in: fileTab, server: server)
            },
            onSuccess: { _ in
                resetPermissionEditor()
            },
            onFailure: { error in
                isPermissionSubmitting = false
                permissionErrorMessage = remoteOperationErrorMessage(for: error)
            }
        )
    }

    func resetPermissionEditor() {
        permissionTargetEntry = nil
        permissionDraft = RemoteFilePermissionDraft(accessBits: 0)
        permissionEditContext = nil
        permissionErrorMessage = nil
        isPermissionSubmitting = false
    }
}
