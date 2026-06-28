import SwiftUI

extension RemoteFileBrowserScreen {
    func beginUpload(to remotePath: String) {
        #if os(macOS)
        presentMacOSUploadPanel(for: remotePath)
        #else
        uploadImportRequest = UploadImportRequest(destinationPath: remotePath)
        #endif
    }

    func beginDownload(_ entry: RemoteFileEntry) {
        guard entry.type != .directory else { return }

        #if os(macOS)
        presentMacOSDownloadPanel(for: entry)
        #else
        cleanupDownloadExport()

        performTransfer(
            title: String(localized: "Downloading"),
            initialMessage: String(localized: "Preparing remote file."),
            successMessage: String(localized: "Download ready to export.")
        ) {
            let temporaryURL = try browser.makeDownloadExportFileURL(for: entry)
            try await browser.downloadFile(
                at: entry.path,
                to: temporaryURL,
                server: server
            )

            await MainActor.run {
                downloadExportDocument = RemoteFileDownloadDocument(sourceURL: temporaryURL)
                downloadExportFilename = entry.name
                isDownloadExporterPresented = true
            }
        }
        #endif
    }

    func beginShare(_ entry: RemoteFileEntry) {
        guard entry.type != .directory else { return }

        cleanupShareItem()

        performTransfer(
            title: String(localized: "Sharing"),
            initialMessage: String(localized: "Preparing remote file."),
            successMessage: String(localized: "Share sheet ready.")
        ) {
            let temporaryURL = try browser.makeDownloadExportFileURL(for: entry)
            try await browser.downloadFile(
                at: entry.path,
                to: temporaryURL,
                server: server
            )

            await MainActor.run {
                shareItem = RemoteFileShareItem(
                    sourceURL: temporaryURL,
                    title: entry.name
                )
            }
        }
    }

    func handleUploadSelection(_ result: Result<[URL], Error>) {
        guard let destinationPath = uploadDestinationPath else { return }
        uploadDestinationPath = nil
        handleUploadSelection(result, to: destinationPath)
    }

    func handleUploadSelection(_ result: Result<[URL], Error>, for request: UploadImportRequest) {
        if uploadImportRequest?.id == request.id {
            uploadImportRequest = nil
        }
        handleUploadSelection(result, to: request.destinationPath)
    }

    func handleUploadSelection(_ result: Result<[URL], Error>, to destinationPath: String) {
        switch result {
        case .success(let urls):
            guard !urls.isEmpty else { return }
            beginUploadFlow(
                urls: urls,
                to: destinationPath,
                initialMessage: String(localized: "Preparing files for upload.")
            )
        case .failure(let error):
            presentOperationError(error)
        }
    }

    func handleDownloadExportCompletion(_ result: Result<URL, Error>) {
        isDownloadExporterPresented = false

        switch result {
        case .success:
            cleanupDownloadExport()
            if let currentNotice = bottomOperationNotice() {
                showNotice(
                    NoticeItem(
                        id: currentNotice.id,
                        lane: .bottomOperation,
                        level: .success,
                        leading: .icon("checkmark.circle.fill"),
                        title: currentNotice.title,
                        message: String(localized: "Export complete."),
                        lifetime: .autoDismiss(.seconds(2))
                    )
                )
            }
        case .failure(let error):
            let nsError = error as NSError
            cleanupDownloadExport()
            guard nsError.code != NSUserCancelledError else { return }
            presentOperationError(error)
        }
    }

    func beginUploadFlow(urls: [URL], to destinationPath: String, initialMessage: String) {
        performTransfer(
            title: String(localized: "Uploading"),
            initialMessage: initialMessage,
            successMessage: String(localized: "Upload complete.")
        ) { onProgress in
            try await uploadResolvedLocalURLs(urls, to: destinationPath, onProgress: onProgress)
        }
    }

    func uploadResolvedLocalURLs(
        _ urls: [URL],
        to destinationPath: String,
        onProgress: @escaping @MainActor @Sendable (RemoteFileBrowserStore.TransferProgress) -> Void
    ) async throws {
        let candidates = try await browser.prepareLocalUploadPlan(
            at: urls,
            to: destinationPath,
            server: server
        )
        let plans = candidates.map { candidate in
            RemoteFileBrowserStore.LocalUploadPlanItem(
                sourceURL: candidate.sourceURL,
                remoteName: candidate.suggestedName ?? candidate.originalName
            )
        }
        try await browser.uploadFiles(
            plans: plans,
            to: destinationPath,
            in: fileTab,
            server: server,
            onProgress: onProgress
        )
    }

    func requestFileRepresentationExport(
        entry: RemoteFileEntry,
        preparedTemporaryURL: Result<URL, Error>,
        progress: Progress,
        completion: @escaping (URL?, Bool, Error?) -> Void
    ) {
        let cancellationTarget = RemoteFileTransferCancellationTarget()
        progress.cancellationHandler = { [browser, cancellationTarget] in
            guard let transferRequestID = cancellationTarget.requestID else { return }
            browser.cancelTransferRequestFromSynchronousCallback(transferRequestID)
        }

        let transferRequestID = browser.requestTransfer(
            serverId: server.id,
            operation: { _ in
                let temporaryURL = try preparedTemporaryURL.get()
                try await browser.downloadItem(entry, to: temporaryURL, server: server)
                try Task.checkCancellation()
                guard !progress.isCancelled else {
                    throw CancellationError()
                }
                return temporaryURL
            },
            onSuccess: { temporaryURL in
                completion(temporaryURL, false, nil)
                progress.completedUnitCount = 1
            },
            onFailure: { error in
                if error is CancellationError {
                    completion(nil, false, CancellationError())
                } else {
                    completion(nil, false, error)
                }
            }
        )
        cancellationTarget.setRequestID(transferRequestID)
        if progress.isCancelled {
            browser.cancelTransferRequestFromSynchronousCallback(transferRequestID)
        }
    }

    func cleanupDownloadExport() {
        if let sourceURL = downloadExportDocument?.sourceURL {
            browser.removeTemporaryFile(at: sourceURL)
        }
        downloadExportDocument = nil
        downloadExportFilename = ""
    }

    func cleanupShareItem() {
        if let sourceURL = shareItem?.sourceURL {
            browser.removeTemporaryFile(at: sourceURL)
        }
        shareItem = nil
    }

    func finishSharing(_ item: RemoteFileShareItem) {
        guard shareItem?.id == item.id else { return }
        cleanupShareItem()
    }
}

private final class RemoteFileTransferCancellationTarget: @unchecked Sendable {
    private let lock = NSLock()
    private var storedRequestID: UUID?

    var requestID: UUID? {
        lock.lock()
        defer { lock.unlock() }
        return storedRequestID
    }

    func setRequestID(_ requestID: UUID) {
        lock.lock()
        storedRequestID = requestID
        lock.unlock()
    }
}
