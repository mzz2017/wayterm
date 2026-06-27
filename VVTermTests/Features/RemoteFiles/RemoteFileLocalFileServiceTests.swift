import Foundation
import Testing
@testable import VVTerm

// Test Context:
// These tests protect the local filesystem adapter used by RemoteFiles transfer
// orchestration. The service owns local file IO and directory creation so the
// browser store can stay focused on transfer intent and remote service usage.
// Update these tests only when local transfer ordering, metadata, or directory
// creation semantics intentionally change.
struct RemoteFileLocalFileServiceTests {
    private let service = RemoteFileLocalFileService()

    @Test
    func loadDataReadsFileContentsOffTheStore() async throws {
        // Given a local file selected for upload or remote-copy staging.
        let rootDirectory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(rootDirectory) }
        let fileURL = rootDirectory.appendingPathComponent("upload.txt")
        try Data("hello".utf8).write(to: fileURL)

        // When the local file service loads the data.
        let data = try await service.loadData(from: fileURL)

        // Then transfer orchestration receives the exact file bytes.
        #expect(String(decoding: data, as: UTF8.self) == "hello")
    }

    @Test
    func itemInfoReportsDisplayNameAndDirectoryFlag() async throws {
        // Given a local directory selected for recursive upload.
        let rootDirectory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(rootDirectory) }
        let directoryURL = rootDirectory.appendingPathComponent("Project", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        // When the local file service reads transfer metadata.
        let info = try await service.itemInfo(at: directoryURL)

        // Then recursive upload planning can distinguish directories from files.
        #expect(info.name == "Project")
        #expect(info.isDirectory)
    }

    @Test
    func directoryContentsAreSortedByLocalizedDisplayName() async throws {
        // Given a local directory whose filesystem enumeration order is not trusted.
        let rootDirectory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(rootDirectory) }
        try Data().write(to: rootDirectory.appendingPathComponent("zeta.txt"))
        try Data().write(to: rootDirectory.appendingPathComponent("alpha.txt"))

        // When the local file service enumerates children.
        let contents = try await service.directoryContents(at: rootDirectory)

        // Then recursive transfer progress and upload order remain stable.
        #expect(contents.map(\.lastPathComponent) == ["alpha.txt", "zeta.txt"])
    }

    @Test
    func createDirectoryCreatesIntermediateDirectories() async throws {
        // Given a nested local download destination that does not exist yet.
        let rootDirectory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(rootDirectory) }
        let directoryURL = rootDirectory.appendingPathComponent("downloads/archive", isDirectory: true)

        // When the local file service creates the destination.
        try await service.createDirectory(at: directoryURL)

        // Then directory downloads can materialize nested local folders.
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory)
        #expect(exists)
        #expect(isDirectory.boolValue)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteFileLocalFileServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func removeTemporaryDirectory(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
