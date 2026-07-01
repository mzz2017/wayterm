import Combine
import Foundation
import os.log

extension RemoteFileBrowserStore {
    @discardableResult
    func requestPreviewLoad(
        for entry: RemoteFileEntry,
        in tab: RemoteFileTab,
        server: Server,
        allowLargeDownloads: Bool = false
    ) -> UUID? {
        previewLoadCoordinator.requestLoad(
            for: entry,
            in: tab,
            server: server,
            allowLargeDownloads: allowLargeDownloads,
            onCancelPrevious: { [weak self] in
                self?.viewerRequestIDs.removeValue(forKey: tab.id)
            },
            loadPreview: { [weak self] in
                guard let self else { return }
                await self.loadPreview(
                    for: entry,
                    in: tab,
                    server: server,
                    allowLargeDownloads: allowLargeDownloads
                )
            }
        )
    }

    func loadPreview(
        for entry: RemoteFileEntry,
        in tab: RemoteFileTab,
        server: Server,
        allowLargeDownloads: Bool = false
    ) async {
        guard tab.serverId == server.id else { return }
        guard entry.supportsPreview else { return }

        let currentState = state(for: tab)
        if currentState.isLoadingViewer, currentState.selectedEntryPath == entry.path {
            return
        }
        if currentState.viewerPayload?.entry.path == entry.path,
           currentState.viewerPayload?.previewKind != .unavailable,
           !(currentState.viewerPayload?.requiresExplicitDownload == true && allowLargeDownloads) {
            return
        }

        if let fileSize = entry.size,
           fileSize > UInt64(Self.previewConfirmationBytes),
           !allowLargeDownloads {
            cleanupPreviewArtifact(for: currentState.viewerPayload)
            viewerRequestIDs.removeValue(forKey: tab.id)
            updateState(for: tab) { state in
                state.selectedEntryPath = entry.path
                state.isLoadingViewer = false
                state.viewerError = nil
                state.viewerPayload = RemoteFileViewerPayload(
                    previewKind: .unavailable,
                    entry: entry,
                    textPreview: nil,
                    previewFileURL: nil,
                    isTruncated: false,
                    unavailableMessage: String(
                        localized: "This file is larger than 1 MB. Download it first if you want to preview it."
                    ),
                    requiresExplicitDownload: true,
                    previewByteCount: fileSize
                )
            }
            return
        }

        let requestID = UUID()
        viewerRequestIDs[tab.id] = requestID
        cleanupPreviewArtifact(for: currentState.viewerPayload)

        updateState(for: tab) { state in
            state.selectedEntryPath = entry.path
            state.isLoadingViewer = true
            state.viewerError = nil
            state.viewerPayload = nil
        }

        do {
            let readLimit = min(Int(entry.size ?? UInt64(Self.defaultPreviewBytes)), Self.hardPreviewBytes)
            let effectiveReadLimit = max(Self.defaultPreviewBytes, readLimit)
            let data = try await withRemoteFileService(for: server) { service in
                try await service.readFile(at: entry.path, maxBytes: effectiveReadLimit)
            }

            guard !Task.isCancelled, viewerRequestIDs[tab.id] == requestID else { return }

            let previewData = data.prefix(Self.defaultPreviewBytes)
            let isTruncated = (entry.size.map { $0 > UInt64(Self.defaultPreviewBytes) } ?? false)
                || data.count > Self.defaultPreviewBytes
                || data.count >= Self.hardPreviewBytes
            let previewKind = previewLoader.previewKind(for: entry, data: previewData)
            let payload: RemoteFileViewerPayload

            switch previewKind {
            case .text:
                payload = RemoteFileViewerPayload(
                    previewKind: .text,
                    entry: entry,
                    textPreview: previewLoader.decodeTextPreview(from: previewData),
                    previewFileURL: nil,
                    isTruncated: isTruncated,
                    unavailableMessage: nil,
                    requiresExplicitDownload: false,
                    previewByteCount: entry.size
                )
            case .image, .video:
                let previewFileURL: URL?
                let unavailableMessage: String?

                if let fileSize = entry.size, fileSize > UInt64(Self.maxMediaPreviewBytes) {
                    previewFileURL = nil
                    unavailableMessage = String(
                        localized: "This file is too large to preview inline. Download it to inspect the full contents."
                    )
                } else {
                    let tempURL = try makePreviewFileURL(for: entry)
                    do {
                        try await withRemoteFileService(for: server) { service in
                            try await service.downloadFile(at: entry.path, to: tempURL)
                        }
                        guard !Task.isCancelled, viewerRequestIDs[tab.id] == requestID else {
                            temporaryStorage.removeItem(at: tempURL)
                            return
                        }
                        if await validateDownloadedPreview(at: tempURL, kind: previewKind) {
                            previewFileURL = tempURL
                            unavailableMessage = nil
                        } else {
                            previewFileURL = tempURL
                            unavailableMessage = String(
                                localized: "This file downloaded successfully, but macOS could not open it for inline preview."
                            )
                        }
                    } catch {
                        temporaryStorage.removeItem(at: tempURL)
                        throw error
                    }
                }

                payload = RemoteFileViewerPayload(
                    previewKind: previewFileURL == nil ? .unavailable : previewKind,
                    entry: entry,
                    textPreview: nil,
                    previewFileURL: previewFileURL,
                    isTruncated: false,
                    unavailableMessage: unavailableMessage,
                    requiresExplicitDownload: false,
                    previewByteCount: entry.size
                )
            case .unavailable:
                payload = RemoteFileViewerPayload(
                    previewKind: .unavailable,
                    entry: entry,
                    textPreview: nil,
                    previewFileURL: nil,
                    isTruncated: false,
                    unavailableMessage: String(localized: "Inline preview is unavailable for this file."),
                    requiresExplicitDownload: false,
                    previewByteCount: entry.size
                )
            }

            guard !Task.isCancelled, viewerRequestIDs[tab.id] == requestID else { return }
            updateState(for: tab) { state in
                state.isLoadingViewer = false
                state.viewerError = nil
                state.viewerPayload = payload
            }
        } catch {
            guard !Task.isCancelled, viewerRequestIDs[tab.id] == requestID else { return }
            logger.error("Remote file preview failed for \(entry.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            updateState(for: tab) { state in
                state.isLoadingViewer = false
                state.viewerPayload = nil
                state.viewerError = RemoteFileBrowserError.map(error)
            }
        }
    }

    func clearViewer(for tab: RemoteFileTab) {
        cancelPreviewLoadRequest(for: tab.id)
        cleanupPreviewArtifact(for: state(for: tab).viewerPayload)
        updateState(for: tab) { state in
            state.selectedEntryPath = nil
            state.viewerPayload = nil
            state.viewerError = nil
            state.isLoadingViewer = false
        }
        viewerRequestIDs.removeValue(forKey: tab.id)
    }

    func saveTextPreview(
        _ text: String,
        for entry: RemoteFileEntry,
        in tab: RemoteFileTab,
        server: Server
    ) async throws {
        guard tab.serverId == server.id else {
            throw RemoteFileBrowserError.disconnected
        }

        guard let data = text.data(using: .utf8) else {
            throw RemoteFileBrowserError.unsupportedEncoding
        }

        let updatedEntry = try await withRemoteFileService(for: server) { service in
            let effectivePermissions = Int32(entry.permissions ?? 0o644)
            try await self.uploadAtomically(data, to: entry.path, permissions: effectivePermissions, using: service)
            return try await service.lstat(at: entry.path)
        }

        try Task.checkCancellation()
        updateState(for: tab) { state in
            if let index = state.entries.firstIndex(where: { $0.path == entry.path }) {
                state.entries[index] = updatedEntry
            }

            if state.selectedEntryPath == entry.path {
                state.viewerPayload = RemoteFileViewerPayload(
                    previewKind: .text,
                    entry: updatedEntry,
                    textPreview: text,
                    previewFileURL: nil,
                    isTruncated: false,
                    unavailableMessage: nil,
                    requiresExplicitDownload: false,
                    previewByteCount: UInt64(data.count)
                )
                state.viewerError = nil
            }
        }
    }

    @discardableResult
    func requestTextPreviewSave(
        _ text: String,
        for entry: RemoteFileEntry,
        in tab: RemoteFileTab,
        server: Server,
        onSaved: @escaping @MainActor @Sendable () -> Void = {},
        onFailure: @escaping @MainActor @Sendable (Error) -> Void = { _ in }
    ) -> UUID {
        requestMutation(
            serverId: server.id,
            operation: {
                try await self.saveTextPreview(text, for: entry, in: tab, server: server)
            },
            onSuccess: onSaved,
            onFailure: onFailure
        )
    }

    func makePreviewFileURL(for entry: RemoteFileEntry) throws -> URL {
        try temporaryStorage.makePreviewFileURL(for: entry)
    }

    func cleanupPreviewArtifact(for payload: RemoteFileViewerPayload?) {
        temporaryStorage.removePreviewArtifact(for: payload)
    }

    func validateDownloadedPreview(at url: URL, kind: RemoteFilePreviewKind) async -> Bool {
        await previewLoader.validateDownloadedPreview(at: url, kind: kind, logger: logger)
    }
}
