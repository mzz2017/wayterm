import Foundation
import Testing

// Test Context:
// These source-boundary tests protect RemoteFiles feature ownership. SwiftUI
// screens should present state and send user intent; feature policy such as
// remote name/path validation belongs in Application or Domain code. Update
// only when this ownership intentionally moves.

struct RemoteFileBrowserScreenBoundaryTests {
    @Test
    func screenDoesNotOwnRemoteNameOrPathValidationPolicy() throws {
        let root = try sourceRoot()
        let screenSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/RemoteFiles/UI/RemoteFileBrowserScreen.swift")
        )
        let transferSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/RemoteFiles/Application/RemoteFileTransferCoordinator.swift")
        )

        // Given the RemoteFiles SwiftUI screen source.
        #expect(
            !screenSource.contains("func validatedRemoteName"),
            "RemoteFileBrowserScreen should not own remote name validation policy."
        )
        #expect(
            !screenSource.contains("func validatedRemoteDirectoryPath"),
            "RemoteFileBrowserScreen should not own remote directory path validation policy."
        )

        // Then the Application layer owns the validation entry points used by UI intent handlers.
        #expect(transferSource.contains("func validatedRemoteName"))
        #expect(transferSource.contains("func validatedRemoteDirectoryPath"))
    }

    @Test
    func screenDoesNotOwnDownloadTemporaryURLCreation() throws {
        let root = try sourceRoot()
        let screenSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/RemoteFiles/UI/RemoteFileBrowserScreen.swift")
        )
        let storageSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/RemoteFiles/Infrastructure/RemoteFileTemporaryStorage.swift")
        )

        // Given the RemoteFiles SwiftUI screen source.
        #expect(
            !screenSource.contains("func temporaryDownloadURL"),
            "RemoteFileBrowserScreen should not own temporary download URL creation."
        )

        // Then RemoteFiles infrastructure owns temporary download export paths.
        #expect(storageSource.contains("func makeDownloadExportFileURL"))
    }

    @Test
    func screenDoesNotOwnDragTemporaryURLCreation() throws {
        let root = try sourceRoot()
        let screenSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/RemoteFiles/UI/RemoteFileBrowserScreen.swift")
        )
        let storageSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/RemoteFiles/Infrastructure/RemoteFileTemporaryStorage.swift")
        )

        // Given the RemoteFiles SwiftUI screen source.
        #expect(
            !screenSource.contains("func temporaryDragExportURL"),
            "RemoteFileBrowserScreen should not own drag export URL creation."
        )
        #expect(
            !screenSource.contains("func temporaryDragExportDirectory"),
            "RemoteFileBrowserScreen should not own drag export directory creation."
        )

        // Then RemoteFiles infrastructure owns temporary drag export paths.
        #expect(storageSource.contains("func makeDragExportFileURL"))
    }

    @Test
    func platformSupportDoesNotOwnMacOSTableViewImplementation() throws {
        let root = try sourceRoot()
        let supportSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/RemoteFiles/UI/Platform/RemoteFileBrowserSupport.swift")
        )
        let tableSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/RemoteFiles/UI/Platform/RemoteFileBrowserMacTableView.swift")
        )
        let cellSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/RemoteFiles/UI/Platform/RemoteFileBrowserMacTableCells.swift")
        )
        let filePromiseSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/RemoteFiles/UI/Platform/RemoteFileBrowserMacFilePromise.swift")
        )

        // Given the platform support source file.
        #expect(
            !supportSource.contains("struct MacOSRemoteFileTableView"),
            "RemoteFileBrowserSupport should not own the large macOS table view implementation."
        )

        // Then the macOS table view lives in its own platform UI file.
        #expect(tableSource.contains("struct MacOSRemoteFileTableView"))
        #expect(
            !tableSource.contains("final class FilePromiseDelegate"),
            "RemoteFileBrowserMacTableView.swift should not own file-promise export glue."
        )
        #expect(
            !tableSource.contains("final class RemoteFileBrowserMacNameCellView"),
            "RemoteFileBrowserMacTableView.swift should not own macOS table cell controls."
        )
        #expect(
            cellSource.contains("final class RemoteFileBrowserMacNameCellView"),
            "RemoteFileBrowserMacTableCells.swift should own macOS table cell controls."
        )
        #expect(
            filePromiseSource.contains("final class FilePromiseDelegate"),
            "RemoteFileBrowserMacFilePromise.swift should own file-promise export glue."
        )
    }

    @Test
    func screenDoesNotOwnActionMenuPresentation() throws {
        let root = try sourceRoot()
        let screenSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/RemoteFiles/UI/RemoteFileBrowserScreen.swift")
        )
        let menuSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/RemoteFiles/UI/RemoteFileBrowserScreen+Menus.swift")
        )

        // Given RemoteFileBrowserScreen is already the root browser surface.
        for functionName in [
            "browserActionMenu",
            "entryActionMenu",
            "inspectorActionMenu",
            "permissionMenuAction",
            "renameAndMoveMenuActions",
            "clipboardMenuActions",
            "deleteMenuAction"
        ] {
            #expect(
                !screenSource.contains("func \(functionName)"),
                "RemoteFileBrowserScreen.swift should not own \(functionName) menu presentation."
            )
            #expect(
                menuSource.contains("func \(functionName)"),
                "RemoteFileBrowserScreen+Menus.swift should own \(functionName) menu presentation."
            )
        }
    }

    @Test
    func screenDoesNotOwnDragDropPresentationGlue() throws {
        let root = try sourceRoot()
        let screenSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/RemoteFiles/UI/RemoteFileBrowserScreen.swift")
        )
        let dragDropSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/RemoteFiles/UI/RemoteFileBrowserScreen+DragDrop.swift")
        )

        // Given drag/drop needs platform data-provider glue but should not
        // keep inflating the root browser surface.
        for functionName in [
            "handleCurrentDirectoryDrop",
            "handleLocalDrop",
            "handleRemoteDrop",
            "handleFolderDrop",
            "dragItemProvider",
            "registerRemoteDragPayload",
            "registerFileRepresentation",
            "dragFileTypeIdentifier",
            "loadDroppedURLs",
            "loadDroppedURL",
            "loadDroppedRemotePayloads",
            "loadDroppedRemotePayload",
            "moveDroppedRemoteItems",
            "performDroppedRemoteMoves",
            "transferDroppedRemoteItems",
            "dragSuggestedName"
        ] {
            #expect(
                !screenSource.contains("func \(functionName)"),
                "RemoteFileBrowserScreen.swift should not own \(functionName) drag/drop glue."
            )
            #expect(
                dragDropSource.contains("func \(functionName)"),
                "RemoteFileBrowserScreen+DragDrop.swift should own \(functionName) drag/drop glue."
            )
        }
    }

    @Test
    func screenDoesNotOwnTransferStatusPresentation() throws {
        let root = try sourceRoot()
        let screenSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/RemoteFiles/UI/RemoteFileBrowserScreen.swift")
        )
        let transferSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/RemoteFiles/UI/RemoteFileBrowserScreen+TransferStatus.swift")
        )

        // Given transfer progress is UI presentation over application-owned
        // request lifecycle state.
        for functionName in [
            "beginTransferStatus",
            "updateTransferStatus",
            "completeTransferStatus",
            "transferProgress",
            "transferDetail",
            "transferCompletionAction",
            "performTransfer"
        ] {
            #expect(
                !screenSource.contains("func \(functionName)"),
                "RemoteFileBrowserScreen.swift should not own \(functionName) transfer presentation."
            )
            #expect(
                transferSource.contains("func \(functionName)"),
                "RemoteFileBrowserScreen+TransferStatus.swift should own \(functionName) transfer presentation."
            )
        }
    }

    @Test
    func screenDoesNotOwnFileTransferGlue() throws {
        let root = try sourceRoot()
        let screenSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/RemoteFiles/UI/RemoteFileBrowserScreen.swift")
        )
        let transferSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/RemoteFiles/UI/RemoteFileBrowserScreen+FileTransfers.swift")
        )

        // Given upload, download, share, and file-promise export are transfer
        // presentation over application-owned request lifecycle state.
        for functionName in [
            "beginUpload",
            "beginDownload",
            "beginShare",
            "handleUploadSelection",
            "handleDownloadExportCompletion",
            "beginUploadFlow",
            "uploadResolvedLocalURLs",
            "requestFileRepresentationExport",
            "cleanupDownloadExport",
            "cleanupShareItem",
            "finishSharing"
        ] {
            #expect(
                !screenSource.contains("func \(functionName)"),
                "RemoteFileBrowserScreen.swift should not own \(functionName) file-transfer glue."
            )
            #expect(
                transferSource.contains("func \(functionName)"),
                "RemoteFileBrowserScreen+FileTransfers.swift should own \(functionName) file-transfer glue."
            )
        }
    }

    @Test
    func screenDoesNotOwnToolbarCommandRouting() throws {
        let root = try sourceRoot()
        let screenSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/RemoteFiles/UI/RemoteFileBrowserScreen.swift")
        )
        let toolbarCommandSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/RemoteFiles/UI/RemoteFileBrowserScreen+ToolbarCommands.swift")
        )

        // Given toolbar commands are external intent routing into the browser
        // surface rather than root view composition.
        #expect(
            !screenSource.contains("func handlePendingToolbarCommand"),
            "RemoteFileBrowserScreen.swift should not own toolbar command routing."
        )
        #expect(
            toolbarCommandSource.contains("func handlePendingToolbarCommand"),
            "RemoteFileBrowserScreen+ToolbarCommands.swift should own toolbar command routing."
        )
    }

    @Test
    func screenDoesNotOwnSheetPresentationHelpers() throws {
        let root = try sourceRoot()
        let screenSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/RemoteFiles/UI/RemoteFileBrowserScreen.swift")
        )
        let sheetSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/RemoteFiles/UI/RemoteFileBrowserScreen+Sheets.swift")
        )

        // Given sheet and alert builders are presentation helpers over
        // RemoteFiles operations, they should not keep inflating the root
        // browser surface.
        for functionName in [
            "renameSheet",
            "moveSheet",
            "deleteSheet",
            "permissionSheet"
        ] {
            #expect(
                !screenSource.contains("func \(functionName)"),
                "RemoteFileBrowserScreen.swift should not own \(functionName) sheet presentation."
            )
            #expect(
                sheetSource.contains("func \(functionName)"),
                "RemoteFileBrowserScreen+Sheets.swift should own \(functionName) sheet presentation."
            )
        }

        for propertyName in [
            "newFolderPromptActions",
            "operationErrorActions",
            "operationErrorMessageView"
        ] {
            #expect(
                !screenSource.contains("var \(propertyName)"),
                "RemoteFileBrowserScreen.swift should not own \(propertyName) presentation."
            )
            #expect(
                sheetSource.contains("var \(propertyName)"),
                "RemoteFileBrowserScreen+Sheets.swift should own \(propertyName) presentation."
            )
        }
    }

    @Test
    func browserSheetCollectionDoesNotOwnPermissionEditorImplementation() throws {
        let root = try sourceRoot()
        let sheetCollectionSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/RemoteFiles/UI/Sheets/RemoteFileBrowserSheets.swift")
        )
        let permissionEditorSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/RemoteFiles/UI/Sheets/RemoteFilePermissionEditorSheet.swift")
        )

        // Given the RemoteFiles sheet collection is already a shared file for
        // multiple dialogs, large self-contained editors should have their own
        // UI file instead of re-growing the collection into a superfile.
        #expect(
            !sheetCollectionSource.contains("struct RemoteFilePermissionEditorSheet"),
            "RemoteFileBrowserSheets.swift should not own the permission editor implementation."
        )
        #expect(
            permissionEditorSource.contains("struct RemoteFilePermissionEditorSheet"),
            "RemoteFilePermissionEditorSheet.swift should own the permission editor implementation."
        )
    }

    @Test
    func screenDoesNotOwnMacOSInlineEditRouting() throws {
        let root = try sourceRoot()
        let screenSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/RemoteFiles/UI/RemoteFileBrowserScreen.swift")
        )
        let inlineEditSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/RemoteFiles/UI/RemoteFileBrowserScreen+MacOSInlineEdit.swift")
        )
        let policySource = try source(
            at: root.appendingPathComponent("VVTerm/Features/RemoteFiles/Application/RemoteFileInlineEditPolicy.swift")
        )

        // Given macOS inline create/rename is platform-specific intent routing
        // over application-owned RemoteFiles operations.
        for functionName in [
            "beginMacOSInlineCreateFolder",
            "createMacOSInlineFolder",
            "cancelMacOSInlineEdit",
            "submitMacOSInlineEdit",
            "selectMacOSEntry",
            "uniqueMacOSFolderName"
        ] {
            #expect(
                !screenSource.contains("func \(functionName)"),
                "RemoteFileBrowserScreen.swift should not own \(functionName) inline-edit routing."
            )
            #expect(
                inlineEditSource.contains("func \(functionName)"),
                "RemoteFileBrowserScreen+MacOSInlineEdit.swift should own \(functionName) inline-edit routing."
            )
        }

        // Then folder-name collision policy lives in Application, not the root UI screen.
        #expect(
            policySource.contains("enum RemoteFileInlineEditPolicy"),
            "RemoteFiles Application should own inline edit naming policy."
        )
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
