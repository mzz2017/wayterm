import SwiftUI

#if os(macOS)
extension RemoteFileBrowserScreen {
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
            submitMacOSInlineCreateFolder(parentPath: parentPath, proposedName: proposedName)
        case .rename(let entryPath, let originalName, _, _):
            submitMacOSInlineRename(entryPath: entryPath, originalName: originalName, proposedName: proposedName)
        }
    }

    func submitMacOSInlineCreateFolder(parentPath: String, proposedName: String) {
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
    }

    func submitMacOSInlineRename(entryPath: String, originalName: String, proposedName: String) {
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

    func selectMacOSEntry(at path: String) {
        macOSSelectedPaths = [path]
        if let entry = browser.entries(for: fileTab).first(where: { $0.path == path }) {
            browser.focus(entry, in: fileTab)
        } else {
            browser.clearViewer(for: fileTab)
        }
    }

    func uniqueMacOSFolderName(in entries: [RemoteFileEntry]) -> String {
        RemoteFileInlineEditPolicy.uniqueFolderName(
            existingNames: entries.map(\.name),
            baseName: String(localized: "Untitled Folder")
        )
    }
}
#endif
