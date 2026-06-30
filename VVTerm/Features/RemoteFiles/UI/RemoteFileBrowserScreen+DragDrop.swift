import SwiftUI
import UniformTypeIdentifiers

struct RemoteFileDropItemProviders: @unchecked Sendable {
    private let providers: [NSItemProvider]

    private init(_ providers: [NSItemProvider]) {
        self.providers = providers
    }

    static func localFileURLs(from providers: [NSItemProvider]) -> RemoteFileDropItemProviders {
        RemoteFileDropItemProviders(
            providers.filter { provider in
                provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
            }
        )
    }

    static func remotePayloads(from providers: [NSItemProvider]) -> RemoteFileDropItemProviders {
        RemoteFileDropItemProviders(
            providers.filter { provider in
                provider.hasItemConformingToTypeIdentifier(UTType.vvtermRemoteFileEntry.identifier)
            }
        )
    }

    var isEmpty: Bool {
        providers.isEmpty
    }

    func forEach(_ body: (NSItemProvider) async throws -> Void) async throws {
        for provider in providers {
            try await body(provider)
        }
    }
}

extension RemoteFileBrowserScreen {
    func handleCurrentDirectoryDrop(_ providers: [NSItemProvider], to destinationPath: String) -> Bool {
        if handleRemoteDrop(providers, to: destinationPath) {
            return true
        }

        return handleLocalDrop(providers, to: destinationPath)
    }

    func handleLocalDrop(_ providers: [NSItemProvider], to destinationPath: String) -> Bool {
        let fileURLProviders = RemoteFileDropItemProviders.localFileURLs(from: providers)
        guard !fileURLProviders.isEmpty else { return false }

        performTransfer(
            title: String(localized: "Uploading"),
            initialMessage: String(localized: "Preparing dropped files."),
            successMessage: String(localized: "Upload complete.")
        ) { onProgress in
            let urls = try await loadDroppedURLs(from: fileURLProviders)
            try await uploadResolvedLocalURLs(urls, to: destinationPath, onProgress: onProgress)
        }

        return true
    }

    func handleRemoteDrop(_ providers: [NSItemProvider], to destinationPath: String) -> Bool {
        let remoteProviders = RemoteFileDropItemProviders.remotePayloads(from: providers)
        guard !remoteProviders.isEmpty else { return false }

        performTransfer(
            title: String(localized: "Transferring"),
            initialMessage: String(localized: "Preparing remote items."),
            successMessage: String(localized: "Transfer complete.")
        ) { onProgress, bindServerScope in
            let payloads = try await loadDroppedRemotePayloads(from: remoteProviders)
            try await transferDroppedRemoteItems(
                payloads,
                to: destinationPath,
                onProgress: onProgress,
                bindServerScope: bindServerScope
            )
        }

        return true
    }

    func handleFolderDrop(_ providers: [NSItemProvider], to entry: RemoteFileEntry) -> Bool {
        guard entry.type == .directory else { return false }
        return handleCurrentDirectoryDrop(providers, to: entry.path)
    }

    func dragItemProvider(for entry: RemoteFileEntry) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = dragSuggestedName(for: [entry])
        registerRemoteDragPayload(for: [entry], in: provider)
        registerFileRepresentation(for: entry, in: provider)
        return provider
    }

    func registerRemoteDragPayload(for entries: [RemoteFileEntry], in provider: NSItemProvider) {
        let encodedPayload = Result {
            try JSONEncoder().encode(RemoteFileDragPayload(serverId: server.id, entries: entries))
        }
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.vvtermRemoteFileEntry.identifier,
            visibility: .ownProcess
        ) { completion in
            do {
                let data = try encodedPayload.get()
                completion(data, nil)
            } catch {
                completion(nil, error)
            }
            return nil
        }
    }

    func registerFileRepresentation(for entry: RemoteFileEntry, in provider: NSItemProvider) {
        let typeIdentifier = dragFileTypeIdentifier(for: entry)
        let preparedTemporaryURL = Result {
            try browser.makeDragExportFileURL(for: entry)
        }
        provider.registerFileRepresentation(
            forTypeIdentifier: typeIdentifier,
            fileOptions: [],
            visibility: .all
        ) { completion in
            let progress = Progress(totalUnitCount: 1)
            Task { @MainActor in
                requestFileRepresentationExport(
                    entry: entry,
                    preparedTemporaryURL: preparedTemporaryURL,
                    progress: progress,
                    completion: completion
                )
            }

            return progress
        }
    }

    func dragFileTypeIdentifier(for entry: RemoteFileEntry) -> String {
        if entry.type == .directory {
            return UTType.folder.identifier
        }

        let pathExtension = URL(fileURLWithPath: entry.name).pathExtension
        return UTType(filenameExtension: pathExtension)?.identifier ?? UTType.data.identifier
    }

    func loadDroppedURLs(from providers: RemoteFileDropItemProviders) async throws -> [URL] {
        var urls: [URL] = []

        try await providers.forEach { provider in
            urls.append(try await loadDroppedURL(from: provider))
        }

        let uniqueURLs = Array(NSOrderedSet(array: urls).compactMap { $0 as? URL })
        guard !uniqueURLs.isEmpty else {
            throw RemoteFileBrowserError.failed(String(localized: "No valid files or folders were dropped."))
        }
        return uniqueURLs
    }

    func loadDroppedURL(from provider: NSItemProvider) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                if let url = item as? URL {
                    continuation.resume(returning: url)
                    return
                }

                if let url = item as? NSURL {
                    continuation.resume(returning: url as URL)
                    return
                }

                if let data = item as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil) {
                    continuation.resume(returning: url)
                    return
                }

                if let text = item as? String,
                   let url = URL(string: text) {
                    continuation.resume(returning: url)
                    return
                }

                continuation.resume(
                    throwing: RemoteFileBrowserError.failed(
                        String(localized: "The dropped item could not be resolved to a local file or folder.")
                    )
                )
            }
        }
    }

    func loadDroppedRemotePayloads(from providers: RemoteFileDropItemProviders) async throws -> [RemoteFileDragPayload] {
        var payloads: [RemoteFileDragPayload] = []

        try await providers.forEach { provider in
            payloads.append(try await loadDroppedRemotePayload(from: provider))
        }

        return try RemoteFileDropPolicy.uniquePayloads(from: payloads)
    }

    func loadDroppedRemotePayload(from provider: NSItemProvider) async throws -> RemoteFileDragPayload {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: UTType.vvtermRemoteFileEntry.identifier) { data, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let data else {
                    continuation.resume(
                        throwing: RemoteFileBrowserError.failed(
                            String(localized: "The dragged remote item could not be decoded.")
                        )
                    )
                    return
                }

                Task { @MainActor in
                    do {
                        let payload = try JSONDecoder().decode(RemoteFileDragPayload.self, from: data)
                        continuation.resume(returning: payload)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    func moveDroppedRemoteItems(
        _ payloads: [RemoteFileDragPayload],
        to destinationDirectoryPath: String,
        onProgress: (@MainActor @Sendable (RemoteFileBrowserStore.TransferProgress) -> Void)? = nil
    ) async throws {
        let moves = try RemoteFileDropPolicy.movePlans(for: payloads, to: destinationDirectoryPath)
        try await performDroppedRemoteMoves(moves, onProgress: onProgress)
    }

    func performDroppedRemoteMoves(
        _ moves: [RemoteFileDropPolicy.MovePlan],
        onProgress: (@MainActor @Sendable (RemoteFileBrowserStore.TransferProgress) -> Void)? = nil
    ) async throws {
        try await browser.moveEntries(moves, in: fileTab, server: server, onProgress: onProgress)
    }

    func transferDroppedRemoteItems(
        _ payloads: [RemoteFileDragPayload],
        to destinationDirectoryPath: String,
        onProgress: RemoteFileBrowserStore.TransferProgressCallback? = nil,
        bindServerScope: RemoteFileBrowserStore.TransferServerScopeBinder? = nil
    ) async throws {
        switch try RemoteFileDropPolicy.plan(
            payloads: payloads,
            to: destinationDirectoryPath,
            destinationServerId: server.id
        ) {
        case .move(let moves):
            try await performDroppedRemoteMoves(moves, onProgress: onProgress)
        case .copy(let sourceServerId, let entries):
            bindServerScope?([sourceServerId])
            try Task.checkCancellation()
            try await browser.copyEntries(
                entries,
                from: sourceServerId,
                to: destinationDirectoryPath,
                destinationTab: fileTab,
                destinationServer: server,
                onProgress: onProgress
            )
        }
    }

    func dragSuggestedName(for entries: [RemoteFileEntry]) -> String? {
        guard entries.count > 1 else {
            guard let name = entries.first?.name, !name.isEmpty else { return nil }
            return name
        }

        return String(
            format: String(localized: "%lld items"),
            Int64(entries.count)
        )
    }
}
