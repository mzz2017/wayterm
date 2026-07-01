#if os(macOS)
import AppKit

extension RemoteFileBrowserScreen {
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
}
#endif
