import Foundation

nonisolated struct RemoteFileLocalItemInfo: Sendable {
    let name: String
    let isDirectory: Bool
}

nonisolated struct RemoteFileLocalFileService {
    func loadData(from url: URL) async throws -> Data {
        try await Task.detached(priority: .utility) {
            try Data(contentsOf: url, options: [.mappedIfSafe])
        }.value
    }

    func itemInfo(at url: URL) async throws -> RemoteFileLocalItemInfo {
        try await Task.detached(priority: .utility) {
            let resourceValues = try url.resourceValues(forKeys: [.isDirectoryKey, .nameKey])
            return RemoteFileLocalItemInfo(
                name: resourceValues.name ?? url.lastPathComponent,
                isDirectory: resourceValues.isDirectory == true
            )
        }.value
    }

    func directoryContents(at url: URL) async throws -> [URL] {
        try await Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            let contents = try fileManager.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey, .nameKey],
                options: []
            )
            return contents.sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
            }
        }.value
    }

    func createDirectory(at url: URL) async throws {
        try await Task.detached(priority: .utility) {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }.value
    }

    func withSecurityScopedAccess<T>(
        to urls: [URL],
        operation: () async throws -> T
    ) async throws -> T {
        let accessedURLs = urls.map { url in
            (url: url, accessed: url.startAccessingSecurityScopedResource())
        }
        defer {
            for entry in accessedURLs where entry.accessed {
                entry.url.stopAccessingSecurityScopedResource()
            }
        }
        return try await operation()
    }
}
