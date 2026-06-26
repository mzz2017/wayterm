import Foundation
import Testing
@testable import VVTerm

// Test Context:
// These tests protect temporary local storage paths and cleanup used by remote
// file previews/transfers. They use isolated temporary directories; update only
// when temporary storage semantics intentionally change.

struct RemoteFileTemporaryStorageTests {
    @Test
    func previewFilesArePlacedInPreviewSubdirectoryAndKeepExtension() throws {
        let rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storage = RemoteFileTemporaryStorage(rootDirectory: rootDirectory)
        let entry = makeEntry(name: "frame.mov", path: "/tmp/frame.mov")

        let url = try storage.makePreviewFileURL(for: entry)

        #expect(url.pathExtension == "mov")
        #expect(url.path.contains("/Previews/"))
    }

    @Test
    func downloadExportFilesUseDownloadsSubdirectoryAndKeepDisplayName() throws {
        let rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storage = RemoteFileTemporaryStorage(rootDirectory: rootDirectory)
        let entry = makeEntry(name: "notes.txt", path: "/tmp/notes.txt")

        // Given a remote file prepared for iOS file export or sharing.
        let url = try storage.makeDownloadExportFileURL(for: entry)

        // Then temporary storage owns the directory and preserves a recognizable name suffix.
        #expect(url.path.contains("/Downloads/"))
        #expect(url.lastPathComponent.hasSuffix("-notes.txt"))
    }

    @Test
    func downloadExportFilesFallbackToDownloadNameForUnnamedEntries() throws {
        let rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storage = RemoteFileTemporaryStorage(rootDirectory: rootDirectory)
        let entry = makeEntry(name: "", path: "/tmp/unnamed")

        let url = try storage.makeDownloadExportFileURL(for: entry)

        #expect(url.lastPathComponent.hasSuffix("-download"))
    }

    @Test
    func dragExportFilesUseDraggedItemsSubdirectoryAndEntryName() throws {
        let rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storage = RemoteFileTemporaryStorage(rootDirectory: rootDirectory)
        let entry = makeEntry(name: "report.pdf", path: "/tmp/report.pdf")

        let url = try storage.makeDragExportFileURL(for: entry)

        #expect(url.path.contains("/DraggedItems/"))
        #expect(url.lastPathComponent == "report.pdf")
    }

    @Test
    func dragExportDirectoriesUseFolderFallbackForUnnamedDirectories() throws {
        let rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storage = RemoteFileTemporaryStorage(rootDirectory: rootDirectory)
        let entry = RemoteFileEntry(
            name: "",
            path: "/tmp/unnamed",
            type: .directory,
            size: nil,
            modifiedAt: nil,
            permissions: nil,
            symlinkTarget: nil
        )

        let url = try storage.makeDragExportFileURL(for: entry)

        #expect(url.lastPathComponent == "Folder")
    }

    @Test
    func removePreviewArtifactDeletesStoredFile() throws {
        let rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storage = RemoteFileTemporaryStorage(rootDirectory: rootDirectory)
        let entry = makeEntry(name: "frame.mov", path: "/tmp/frame.mov")
        let previewURL = try storage.makePreviewFileURL(for: entry)
        try Data([0x01, 0x02]).write(to: previewURL)
        let payload = RemoteFileViewerPayload(
            previewKind: .video,
            entry: entry,
            textPreview: nil,
            previewFileURL: previewURL,
            isTruncated: false,
            unavailableMessage: nil,
            requiresExplicitDownload: false,
            previewByteCount: 2
        )

        storage.removePreviewArtifact(for: payload)

        #expect(!FileManager.default.fileExists(atPath: previewURL.path))
    }

    private func makeEntry(name: String, path: String) -> RemoteFileEntry {
        RemoteFileEntry(
            name: name,
            path: path,
            type: .file,
            size: nil,
            modifiedAt: nil,
            permissions: nil,
            symlinkTarget: nil
        )
    }
}
