#if os(macOS)
import AppKit

@MainActor
final class FilePromiseDelegate: NSObject, NSFilePromiseProviderDelegate {
    let id = UUID()
    private let entry: RemoteFileEntry
    private let fileTypeIdentifier: String
    private let export: @MainActor (RemoteFileEntry, URL, @escaping @MainActor (Error?) -> Void) -> Void
    private let onCompletion: @MainActor (UUID) -> Void

    init(
        entry: RemoteFileEntry,
        fileTypeIdentifier: String,
        export: @escaping @MainActor (RemoteFileEntry, URL, @escaping @MainActor (Error?) -> Void) -> Void,
        onCompletion: @escaping @MainActor (UUID) -> Void = { _ in }
    ) {
        self.entry = entry
        self.fileTypeIdentifier = fileTypeIdentifier
        self.export = export
        self.onCompletion = onCompletion
    }

    func makeProvider() -> NSFilePromiseProvider {
        NSFilePromiseProvider(fileType: fileTypeIdentifier, delegate: self)
    }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
        .main
    }

    func promisedFileName(for fileType: String) -> String {
        let fallbackName = entry.type == .directory ? "Folder" : "download"
        let trimmedName = entry.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedName.isEmpty ? fallbackName : trimmedName
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        promisedFileName(for: fileType)
    }

    func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        writePromiseTo url: URL,
        completionHandler: @escaping (Error?) -> Void
    ) {
        MainActor.assumeIsolated {
            export(entry, url) { [id, onCompletion] error in
                completionHandler(error)
                onCompletion(id)
            }
        }
    }
}
#endif
