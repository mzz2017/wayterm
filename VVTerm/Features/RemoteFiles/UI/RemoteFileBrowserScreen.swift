import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
#else
import UIKit
#endif

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
    @State var permissionOriginalAccessBits: UInt32 = 0
    @State var permissionPreservedBits: UInt32 = 0
    @State var permissionFileTypeBits: UInt32 = 0
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
        [UTType.vvtermRemoteFileEntry.identifier, UTType.fileURL.identifier]
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

    @ViewBuilder
    var newFolderPromptActions: some View {
        TextField(String(localized: "Folder Name"), text: $newFolderName)

        Button(String(localized: "Create")) {
            createFolder()
        }
        .disabled(trimmedNewFolderName.isEmpty || isCreateFolderSubmitting)

        Button(String(localized: "Cancel"), role: .cancel) {
            resetNewFolderPrompt()
        }
    }

    var newFolderPromptMessage: Text {
        Text(String(localized: "Create a folder in the current remote directory."))
    }

    @ViewBuilder
    var operationErrorActions: some View {
        Button(String(localized: "OK"), role: .cancel) {
            operationErrorMessage = nil
        }
    }

    var operationErrorMessageView: Text {
        Text(operationErrorText)
    }

    @ViewBuilder
    func renameSheet(entry: RemoteFileEntry) -> some View {
        RemoteFileRenameSheet(
            entry: entry,
            proposedName: $renameName,
            isSubmitting: isRenameSubmitting,
            onCancel: resetRenamePrompt,
            onRename: { renameEntry() }
        )
        #if os(macOS)
        .frame(
            minWidth: 460,
            idealWidth: 500,
            maxWidth: 560,
            minHeight: 220,
            idealHeight: 240,
            maxHeight: 280
        )
        #endif
    }

    func moveSheet(entry: RemoteFileEntry) -> some View {
        return RemoteFileMoveSheet(
            entry: entry,
            destinationDirectory: $moveDestinationDirectory,
            onRequestDirectories: { path, onCompleted in
                browser.requestMoveDestinationLoad(
                    path: path,
                    server: server,
                    onCompleted: onCompleted
                )
            },
            isSubmitting: isMoveSubmitting,
            onCancel: resetMovePrompt,
            onMove: moveEntry
        )
        #if os(macOS)
        .frame(
            minWidth: 460,
            idealWidth: 500,
            maxWidth: 560,
            minHeight: 420,
            idealHeight: 520,
            maxHeight: 620
        )
        #endif
    }

    @ViewBuilder
    func deleteSheet(entry: RemoteFileEntry) -> some View {
        RemoteFileDeleteConfirmationSheet(
            entry: entry,
            message: deleteAlertMessage(for: entry),
            onCancel: { deleteTargetEntry = nil },
            onDelete: deleteEntry
        )
    }

    @ViewBuilder
    func permissionSheet(entry: RemoteFileEntry) -> some View {
        RemoteFilePermissionEditorSheet(
            entry: entry,
            draft: $permissionDraft,
            originalAccessBits: permissionOriginalAccessBits,
            preservedBits: permissionPreservedBits,
            errorMessage: permissionErrorMessage,
            isSubmitting: isPermissionSubmitting,
            onCancel: resetPermissionEditor,
            onApply: applyPermissions
        )
        #if os(macOS)
        .frame(
            minWidth: 460,
            idealWidth: 500,
            maxWidth: 560,
            minHeight: 520,
            idealHeight: 580,
            maxHeight: 680
        )
        #endif
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
        onFailure: (@MainActor (Error) -> Void)? = nil,
        operation: @escaping @MainActor () async throws -> Void
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
        operation: @escaping @MainActor () async throws -> Result,
        onSuccess: @escaping @MainActor (Result) -> Void,
        onFailure: (@MainActor (Error) -> Void)? = nil
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
        guard canEditPermissions(for: entry), let permissions = entry.permissions else { return }
        permissionTargetEntry = entry
        permissionDraft = RemoteFilePermissionDraft(accessBits: permissions)
        permissionOriginalAccessBits = permissions & 0o777
        permissionPreservedBits = entry.specialPermissionBits
        permissionFileTypeBits = permissions & UInt32(LIBSSH2_SFTP_S_IFMT)
        permissionErrorMessage = nil
        isPermissionSubmitting = false
    }

    func canEditPermissions(for entry: RemoteFileEntry) -> Bool {
        guard entry.permissions != nil else { return false }
        switch entry.type {
        case .symlink:
            return false
        case .file, .directory, .other:
            return true
        }
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
            for entry in entries {
                try await browser.deleteItem(
                    at: entry.path,
                    in: fileTab,
                    server: server,
                    type: entry.type
                )
            }
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

    #if os(macOS)
    func beginMacOSInlineCreateFolder(in remotePath: String) {
        let destinationPath = RemoteFilePath.normalize(remotePath, relativeTo: snapshot.currentPath)

        guard snapshot.currentPath != destinationPath else {
            createMacOSInlineFolder(in: destinationPath)
            return
        }

        browser.requestNavigation(
            .openBreadcrumb(RemoteFileBreadcrumb(title: "", path: destinationPath)),
            in: fileTab,
            server: server,
            onCompleted: { result in
                guard case .loadedDirectory(let loadedPath) = result,
                      loadedPath == destinationPath else {
                    return
                }
                createMacOSInlineFolder(in: destinationPath)
            }
        )
    }

    func createMacOSInlineFolder(in destinationPath: String) {
        let folderName = uniqueMacOSFolderName(in: browser.entries(for: fileTab))
        let createdPath = RemoteFilePath.appending(folderName, to: destinationPath)

        performOperation(
            operation: {
                try await browser.createDirectory(
                    named: folderName,
                    in: destinationPath,
                    tab: fileTab,
                    server: server
                )
            },
            onSuccess: { _ in
                macOSSelectedPaths = [createdPath]
                browser.clearViewer(for: fileTab)
                macOSInlineEditor = .rename(
                    entryPath: createdPath,
                    originalName: folderName,
                    proposedName: folderName,
                    isSubmitting: false
                )
            }
        )
    }

    func cancelMacOSInlineEdit() {
        guard macOSInlineEditor?.isSubmitting != true else { return }
        macOSInlineEditor = nil
    }

    func submitMacOSInlineEdit(_ proposedName: String) {
        guard let editor = macOSInlineEditor, !editor.isSubmitting else { return }

        switch editor {
        case .createFolder(let parentPath, _, _):
            let trimmedName = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty else {
                macOSInlineEditor = nil
                return
            }
            do {
                let validatedName = try browser.validatedRemoteName(proposedName)
                let createdPath = RemoteFilePath.appending(validatedName, to: parentPath)
                macOSInlineEditor = .createFolder(
                    parentPath: parentPath,
                    proposedName: proposedName,
                    isSubmitting: true
                )

                performOperation(
                    operation: {
                        try await browser.createDirectory(
                            named: validatedName,
                            in: parentPath,
                            tab: fileTab,
                            server: server
                        )
                    },
                    onSuccess: { _ in
                        macOSInlineEditor = nil
                        selectMacOSEntry(at: createdPath)
                    },
                    onFailure: { error in
                        macOSInlineEditor = .createFolder(
                            parentPath: parentPath,
                            proposedName: proposedName,
                            isSubmitting: false
                        )
                        presentOperationError(error)
                    }
                )
            } catch {
                macOSInlineEditor = .createFolder(
                    parentPath: parentPath,
                    proposedName: proposedName,
                    isSubmitting: false
                )
                presentOperationError(error)
            }

        case .rename(let entryPath, let originalName, _, _):
            do {
                let validatedName = try browser.validatedRemoteName(proposedName)
                if validatedName == originalName {
                    macOSInlineEditor = nil
                    return
                }

                let destinationPath = RemoteFilePath.appending(
                    validatedName,
                    to: RemoteFilePath.parent(of: entryPath)
                )

                macOSInlineEditor = .rename(
                    entryPath: entryPath,
                    originalName: originalName,
                    proposedName: proposedName,
                    isSubmitting: true
                )

                performOperation(
                    operation: {
                        try await browser.renameItem(
                            at: entryPath,
                            to: destinationPath,
                            in: fileTab,
                            server: server
                        )
                    },
                    onSuccess: { _ in
                        macOSInlineEditor = nil
                        selectMacOSEntry(at: destinationPath)
                    },
                    onFailure: { error in
                        macOSInlineEditor = .rename(
                            entryPath: entryPath,
                            originalName: originalName,
                            proposedName: proposedName,
                            isSubmitting: false
                        )
                        presentOperationError(error)
                    }
                )
            } catch {
                macOSInlineEditor = .rename(
                    entryPath: entryPath,
                    originalName: originalName,
                    proposedName: proposedName,
                    isSubmitting: false
                )
                presentOperationError(error)
            }
        }
    }

    func selectMacOSEntry(at path: String) {
        macOSSelectedPaths = [path]
        if let entry = browser.entries(for: fileTab).first(where: { $0.path == path }) {
            browser.focus(entry, in: fileTab)
        } else {
            browser.clearViewer(for: fileTab)
        }
    }

    func uniqueMacOSFolderName(in entries: [RemoteFileEntry]) -> String {
        let baseName = String(localized: "Untitled Folder")
        let existingNames = Set(entries.map { $0.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) })

        guard !existingNames.contains(baseName.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)) else {
            for index in 2...10_000 {
                let candidate = "\(baseName) \(index)"
                let foldedCandidate = candidate.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                if !existingNames.contains(foldedCandidate) {
                    return candidate
                }
            }

            return "\(baseName) \(UUID().uuidString.prefix(4))"
        }

        return baseName
    }
    #endif

    func applyPermissions() {
        guard let entry = permissionTargetEntry, !isPermissionSubmitting else { return }
        permissionErrorMessage = nil
        isPermissionSubmitting = true

        performOperation(
            operation: {
                let requestedPermissions = permissionFileTypeBits | permissionPreservedBits | permissionDraft.accessBits
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
        permissionOriginalAccessBits = 0
        permissionPreservedBits = 0
        permissionFileTypeBits = 0
        permissionErrorMessage = nil
        isPermissionSubmitting = false
    }

    func currentFolderTitle(for path: String) -> String {
        RemoteFilePath.breadcrumbs(for: path).last?.title ?? "/"
    }

    #if os(macOS)
    func presentMacOSUploadPanel(for remotePath: String) {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Upload to Remote Folder")
        panel.message = String(localized: "Choose files or folders to upload.")
        panel.prompt = String(localized: "Upload")
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.resolvesAliases = true

        let response = panel.runModal()
        guard response == .OK else { return }

        let urls = panel.urls
        guard !urls.isEmpty else { return }

        beginUploadFlow(
            urls: urls,
            to: remotePath,
            initialMessage: String(localized: "Preparing files for upload.")
        )
    }

    func presentMacOSDownloadPanel(for entry: RemoteFileEntry) {
        let panel = NSSavePanel()
        panel.title = String(localized: "Download Remote File")
        panel.message = String(localized: "Choose where to save the downloaded file.")
        panel.nameFieldStringValue = entry.name.isEmpty ? "download" : entry.name
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false

        let response = panel.runModal()
        guard response == .OK, let destinationURL = panel.url else { return }

        performTransfer(
            title: String(localized: "Downloading"),
            initialMessage: String(localized: "Downloading remote file."),
            successMessage: String(localized: "Download complete."),
            successFileURL: destinationURL,
            successFileName: destinationURL.lastPathComponent,
            successFilePath: destinationURL.path
        ) {
            try await browser.downloadFile(
                at: entry.path,
                to: destinationURL,
                server: server
            )
        }
    }

    func presentMacOSDeleteConfirmation(for entries: [RemoteFileEntry]) {
        let sortedEntries = entries.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.icon = NSImage(systemSymbolName: "trash", accessibilityDescription: String(localized: "Delete"))

        if sortedEntries.count == 1, let entry = sortedEntries.first {
            alert.messageText = deleteAlertTitle(for: entry)
            alert.informativeText = deleteAlertMessage(for: entry)
        } else {
            alert.messageText = String(
                format: String(localized: "Delete %lld Items?"),
                Int64(sortedEntries.count)
            )

            let previewNames = sortedEntries.prefix(3).map(\.name).joined(separator: ", ")
            if sortedEntries.count > 3 {
                alert.informativeText = String(
                    format: String(localized: "This will permanently remove %@ and %lld more items from the remote server. This cannot be undone."),
                    previewNames,
                    Int64(sortedEntries.count - 3)
                )
            } else {
                alert.informativeText = String(
                    format: String(localized: "This will permanently remove %@ from the remote server. This cannot be undone."),
                    previewNames
                )
            }
        }

        alert.addButton(withTitle: String(localized: "Delete"))
        alert.addButton(withTitle: String(localized: "Cancel"))

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }
        deleteEntries(sortedEntries)
    }
    #endif

    func itemCountLabel(for count: Int) -> String {
        count == 1
            ? String(format: String(localized: "%lld item"), Int64(count))
            : String(format: String(localized: "%lld items"), Int64(count))
    }

    func modifiedLabel(for entry: RemoteFileEntry) -> String {
        guard let modifiedAt = entry.modifiedAt else { return "—" }
        return modifiedAt.formatted(date: .abbreviated, time: .shortened)
    }

    func deleteAlertTitle(for entry: RemoteFileEntry) -> String {
        switch entry.type {
        case .directory:
            return String(localized: "Delete Folder?")
        case .file:
            return String(localized: "Delete File?")
        case .symlink, .other:
            return String(localized: "Delete Item?")
        }
    }

    func sizeLabel(for entry: RemoteFileEntry) -> String {
        guard entry.type != .directory, let size = entry.size else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }

    func kindLabel(for entry: RemoteFileEntry) -> String {
        switch entry.type {
        case .directory:
            return String(localized: "Folder")
        case .symlink:
            return String(localized: "Symlink")
        case .other:
            return String(localized: "Document")
        case .file:
            let ext = URL(fileURLWithPath: entry.name).pathExtension.lowercased()
            switch ext {
            case "yaml", "yml":
                return String(localized: "YAML Document")
            case "json":
                return String(localized: "JSON Document")
            case "md":
                return String(localized: "Markdown Document")
            case "txt", "log":
                return String(localized: "Text Document")
            case "swift":
                return String(localized: "Swift Source")
            case "sh", "bash", "zsh":
                return String(localized: "Shell Script")
            case "png", "jpg", "jpeg", "gif", "webp", "heic":
                return String(localized: "Image")
            case "zip", "tar", "gz", "tgz", "xz", "bz2":
                return String(localized: "Archive")
            default:
                return String(localized: "Document")
            }
        }
    }

}
