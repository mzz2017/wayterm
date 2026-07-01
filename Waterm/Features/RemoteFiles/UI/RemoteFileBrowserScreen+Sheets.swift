import SwiftUI

extension RemoteFileBrowserScreen {
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
            originalAccessBits: permissionEditContext?.originalAccessBits ?? 0,
            preservedBits: permissionEditContext?.preservedBits ?? 0,
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
}
