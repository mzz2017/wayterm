import Foundation

nonisolated final class RemoteFileTemporaryStorage: @unchecked Sendable {
    private let lock = NSLock()
    private let fileManager: FileManager
    private let rootDirectory: URL

    init(
        fileManager: FileManager = .default,
        rootDirectory: URL = FileManager.default.temporaryDirectory.appendingPathComponent("WatermRemoteFiles", isDirectory: true)
    ) {
        self.fileManager = fileManager
        self.rootDirectory = rootDirectory
    }

    func makePreviewFileURL(for entry: RemoteFileEntry) throws -> URL {
        try makeFileURL(in: "Previews", suggestedName: entry.name)
    }

    func makeTransferFileURL(for entry: RemoteFileEntry) throws -> URL {
        try makeFileURL(in: "Transfers", suggestedName: entry.name.isEmpty ? "download" : entry.name)
    }

    func makeDownloadExportFileURL(for entry: RemoteFileEntry) throws -> URL {
        try makeNamedFileURL(in: "Downloads", suggestedName: entry.name.isEmpty ? "download" : entry.name)
    }

    func makeDragExportFileURL(for entry: RemoteFileEntry) throws -> URL {
        let exportDirectory = try makeDragExportDirectory()
        let fallbackName = entry.type == .directory ? "Folder" : "download"
        let filename = entry.name.isEmpty ? fallbackName : entry.name
        return exportDirectory.appendingPathComponent(filename, isDirectory: entry.type == .directory)
    }

    func makeDragExportDirectory(named folderName: String? = nil) throws -> URL {
        lock.lock()
        defer { lock.unlock() }
        return try makeDragExportDirectoryLocked(named: folderName)
    }

    func removeItem(at url: URL) {
        lock.lock()
        defer { lock.unlock() }
        try? fileManager.removeItem(at: url)
    }

    func removePreviewArtifact(for payload: RemoteFileViewerPayload?) {
        guard let previewFileURL = payload?.previewFileURL else { return }
        removeItem(at: previewFileURL)
    }

    private func makeFileURL(in subdirectoryName: String, suggestedName: String) throws -> URL {
        lock.lock()
        defer { lock.unlock() }

        let directory = rootDirectory.appendingPathComponent(subdirectoryName, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let fileURL = URL(fileURLWithPath: suggestedName)
        let fileExtension = fileURL.pathExtension
        var url = directory.appendingPathComponent(UUID().uuidString)
        if !fileExtension.isEmpty {
            url.appendPathExtension(fileExtension)
        }
        return url
    }

    private func makeNamedFileURL(in subdirectoryName: String, suggestedName: String) throws -> URL {
        lock.lock()
        defer { lock.unlock() }

        let directory = rootDirectory.appendingPathComponent(subdirectoryName, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        return directory.appendingPathComponent("\(UUID().uuidString)-\(suggestedName)")
    }

    private func makeDragExportDirectoryLocked(named folderName: String?) throws -> URL {
        let rootDirectory = rootDirectory.appendingPathComponent("DraggedItems", isDirectory: true)
        try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)

        let trimmedFolderName = folderName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let directoryName = trimmedFolderName.isEmpty ? UUID().uuidString : trimmedFolderName
        let exportDirectory = rootDirectory.appendingPathComponent(directoryName, isDirectory: true)
        try fileManager.createDirectory(at: exportDirectory, withIntermediateDirectories: true)
        return exportDirectory
    }
}
