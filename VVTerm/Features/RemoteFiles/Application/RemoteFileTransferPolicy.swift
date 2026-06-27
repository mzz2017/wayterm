import Foundation

nonisolated struct RemoteFileLocalUploadPlanItem: Identifiable, Sendable {
    let sourceURL: URL
    let remoteName: String

    var id: String {
        "\(sourceURL.absoluteString)->\(remoteName)"
    }
}

nonisolated struct RemoteFileTransferPolicy {
    func uploadPlans(for urls: [URL]) -> [RemoteFileLocalUploadPlanItem] {
        urls.map { RemoteFileLocalUploadPlanItem(sourceURL: $0, remoteName: $0.lastPathComponent) }
    }

    func uniqueTransferEntries(_ entries: [RemoteFileEntry]) -> [RemoteFileEntry] {
        var seenPaths: Set<String> = []
        return entries.filter { seenPaths.insert($0.path).inserted }
    }

    func validatedRemoteName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw RemoteFileBrowserError.failed(String(localized: "A name is required."))
        }
        guard trimmed != "." && trimmed != ".." else {
            throw RemoteFileBrowserError.failed(String(localized: "This name is not allowed."))
        }
        guard !trimmed.contains("/") else {
            throw RemoteFileBrowserError.failed(String(localized: "Names cannot contain '/'."))
        }
        return trimmed
    }

    func validatedRemoteDirectoryPath(_ path: String, relativeTo currentPath: String) throws -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw RemoteFileBrowserError.failed(String(localized: "Destination folder cannot be empty."))
        }
        return RemoteFilePath.normalize(trimmed, relativeTo: currentPath)
    }
}
