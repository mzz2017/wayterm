import Foundation
import Testing
@testable import Waterm

// Test Context:
// These tests protect RemoteFileInspector metadata/action presentation policy.
// RemoteFileInspectorView should compose metadata UI and send callbacks, while
// metadata/action availability rules live in the sibling metadata view helpers.
// Update only when remote file inspector actions or metadata labels intentionally
// change.
struct RemoteFileInspectorMetadataViewsTests {
    @Test
    func actionAvailabilityRejectsDirectoriesAndSymlinkPermissionEditing() {
        let actions = RemoteFileInspectorActions(
            onDownload: { _ in },
            onShare: { _ in },
            onRename: { _ in },
            onMove: { _ in },
            onEditPermissions: { _ in },
            onDelete: { _ in }
        )
        let directory = entry(name: "logs", type: .directory, permissions: 0o755)
        let symlink = entry(name: "current", type: .symlink, permissions: 0o777, symlinkTarget: "/srv/releases/1")

        // Given directory and symlink entries.
        // Then destructive and metadata actions remain available through callbacks,
        // but file-transfer and chmod rules stay type-aware.
        #expect(actions.canDownload(directory) == false)
        #expect(actions.canShare(directory) == false)
        #expect(actions.canEditPermissions(directory) == true)
        #expect(actions.canEditPermissions(symlink) == false)
        #expect(actions.showsPrimaryActions(for: directory) == true)
    }

    @Test
    func metadataPolicyFormatsKindSizeAndMissingValues() {
        let file = entry(
            name: "report.txt",
            type: .file,
            size: 2048,
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let directory = entry(name: "config", type: .directory)

        // Given file and directory metadata.
        // Then labels match the inspector's stable presentation rules.
        #expect(RemoteFileInspectorMetadataPolicy.kindLabel(for: file) == "Document")
        #expect(RemoteFileInspectorMetadataPolicy.sizeLabel(for: file) == "2 KB")
        #expect(RemoteFileInspectorMetadataPolicy.sizeLabel(for: directory) == "—")
        #expect(RemoteFileInspectorMetadataPolicy.subtitle(for: directory) == "Folder")
        #expect(RemoteFileInspectorMetadataPolicy.modifiedLabel(for: directory) == "—")
    }

    private func entry(
        name: String,
        type: RemoteFileType,
        size: UInt64? = nil,
        modifiedAt: Date? = nil,
        permissions: UInt32? = nil,
        symlinkTarget: String? = nil
    ) -> RemoteFileEntry {
        RemoteFileEntry(
            name: name,
            path: "/tmp/\(name)",
            type: type,
            size: size,
            modifiedAt: modifiedAt,
            permissions: permissions,
            symlinkTarget: symlinkTarget
        )
    }
}
