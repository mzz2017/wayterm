import Foundation
import Testing
@testable import Waterm

// Test Context:
// These tests protect RemoteFiles transfer policy without remote service,
// security-scoped URL, or filesystem side effects. RemoteFileBrowserStore owns
// transfer orchestration, while RemoteFileTransferPolicy owns value-only upload
// planning, destination validation, and duplicate-entry filtering. Update only
// when transfer policy semantics intentionally change.
struct RemoteFileTransferPolicyTests {
    private let policy = RemoteFileTransferPolicy()

    @Test
    func uploadPlansUseLocalFilenameAsDefaultRemoteName() {
        let urls = [
            URL(fileURLWithPath: "/tmp/release notes.txt"),
            URL(fileURLWithPath: "/tmp/archive.tar.gz")
        ]

        // Given local URLs selected for upload without conflict resolution yet.
        let plans = policy.uploadPlans(for: urls)

        // Then default remote names match each local file name.
        #expect(plans.map(\.sourceURL) == urls)
        #expect(plans.map(\.remoteName) == ["release notes.txt", "archive.tar.gz"])
    }

    @Test
    func validatedRemoteNameTrimsWhitespace() throws {
        let result = try policy.validatedRemoteName("  notes.txt \n")

        #expect(result == "notes.txt")
    }

    @Test
    func validatedRemoteNameRejectsSlashSeparatedPaths() {
        #expect(throws: RemoteFileBrowserError.self) {
            try policy.validatedRemoteName("nested/path.txt")
        }
    }

    @Test
    func validatedRemoteDirectoryPathTrimsAndNormalizesRelativeDestination() throws {
        // Given a user-entered destination relative to the current directory.
        let result = try policy.validatedRemoteDirectoryPath(" ../logs/./today ", relativeTo: "/var/tmp/cache")

        // Then validation trims UI text and delegates path semantics to RemoteFilePath.
        #expect(result == "/var/tmp/logs/today")
    }

    @Test
    func validatedRemoteDirectoryPathRejectsEmptyDestination() {
        #expect(throws: RemoteFileBrowserError.self) {
            try policy.validatedRemoteDirectoryPath(" \n ", relativeTo: "/var/tmp/cache")
        }
    }

    @Test
    func uniqueTransferEntriesRemovesDuplicatePaths() {
        let duplicate = makeEntry(name: "a.txt", path: "/tmp/a.txt")
        let unique = makeEntry(name: "b.txt", path: "/tmp/b.txt")

        // Given duplicate entries may arrive from multi-selection or drag state.
        let deduped = policy.uniqueTransferEntries([duplicate, unique, duplicate])

        // Then first occurrence order is preserved and later duplicates drop.
        #expect(deduped.map(\.path) == ["/tmp/a.txt", "/tmp/b.txt"])
    }

    private func makeEntry(name: String, path: String, type: RemoteFileType = .file) -> RemoteFileEntry {
        RemoteFileEntry(
            name: name,
            path: path,
            type: type,
            size: nil,
            modifiedAt: nil,
            permissions: nil,
            symlinkTarget: nil
        )
    }
}
