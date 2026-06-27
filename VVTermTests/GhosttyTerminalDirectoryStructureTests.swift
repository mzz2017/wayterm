import Foundation
import Testing

// Test Context:
// These source-boundary tests protect AGENTS.md directory ownership rules for
// GhosttyTerminal. The folder is module-like, so source should live under
// explicit owner folders instead of returning to a flat pile of Swift files.
// Update this test only when AGENTS.md intentionally changes the owner folders.
@Suite(.serialized)
struct GhosttyTerminalDirectoryStructureTests {
    @Test
    func ghosttyTerminalUsesOwnerDirectoriesInsteadOfRootSwiftFiles() throws {
        let root = try sourceRoot().appendingPathComponent("VVTerm/GhosttyTerminal")
        let fileManager = FileManager.default

        // Given the GhosttyTerminal source root.
        let rootEntries = try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey]
        )
        let rootSwiftFiles = try rootEntries.filter { url in
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            return values.isRegularFile == true && url.pathExtension == "swift"
        }

        // Then Swift source should be organized under explicit owner folders.
        #expect(
            rootSwiftFiles.isEmpty,
            "GhosttyTerminal root should not contain Swift files; use Bridge, Shared, Surface, iOS/<Owner>, or macOS."
        )

        for owner in ["Bridge", "Shared", "Surface", "iOS", "macOS"] {
            let url = root.appendingPathComponent(owner)
            var isDirectory: ObjCBool = false
            #expect(
                fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue,
                "GhosttyTerminal/\(owner) should exist as an ownership boundary."
            )
        }
    }

    private func sourceRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.lastPathComponent != "VVTermTests" {
            let next = url.deletingLastPathComponent()
            if next.path == url.path {
                throw SourceRootError.notFound
            }
            url = next
        }
        return url.deletingLastPathComponent()
    }

    private enum SourceRootError: Error {
        case notFound
    }
}
