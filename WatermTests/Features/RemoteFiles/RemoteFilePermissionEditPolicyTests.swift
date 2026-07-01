import Foundation
import Testing
@testable import Waterm

// Test Context:
// Remote file permission editing is presented by SwiftUI, but chmod eligibility
// and POSIX/SFTP bit composition belong to RemoteFiles application policy. These
// tests protect that boundary so UI code does not re-own symlink filtering,
// special permission preservation, or file-type bit preservation.

struct RemoteFilePermissionEditPolicyTests {
    @Test
    func canEditPermissionsRequiresStoredPermissionsAndRejectsSymlinks() {
        // Given entries that cover the permission editor availability rules.
        let regularFile = entry(type: .file, permissions: UInt32(LIBSSH2_SFTP_S_IFREG) | 0o644)
        let directory = entry(type: .directory, permissions: UInt32(LIBSSH2_SFTP_S_IFDIR) | 0o755)
        let missingPermissions = entry(type: .file, permissions: nil)
        let symlink = entry(type: .symlink, permissions: UInt32(LIBSSH2_SFTP_S_IFLNK) | 0o777)

        // When the application policy evaluates editor availability.
        // Then only entries with known permissions and non-symlink types can be edited.
        #expect(RemoteFilePermissionEditPolicy.canEditPermissions(for: regularFile))
        #expect(RemoteFilePermissionEditPolicy.canEditPermissions(for: directory))
        #expect(!RemoteFilePermissionEditPolicy.canEditPermissions(for: missingPermissions))
        #expect(!RemoteFilePermissionEditPolicy.canEditPermissions(for: symlink))
    }

    @Test
    func contextSplitsOriginalAccessSpecialAndFileTypeBits() throws {
        // Given a directory permission value that includes type, setuid, and access bits.
        let permissions = UInt32(LIBSSH2_SFTP_S_IFDIR) | 0o4755
        let directory = entry(type: .directory, permissions: permissions)

        // When the application policy creates an edit context.
        let context = try #require(RemoteFilePermissionEditPolicy.context(for: directory))

        // Then UI receives display/edit inputs without owning POSIX bit masking.
        #expect(context.draft.accessBits == 0o755)
        #expect(context.originalAccessBits == 0o755)
        #expect(context.preservedBits == 0o4000)
        #expect(context.fileTypeBits == UInt32(LIBSSH2_SFTP_S_IFDIR))
    }

    @Test
    func requestedPermissionsPreservesFileTypeAndSpecialBits() throws {
        // Given an edit context with directory and setgid bits from the original entry.
        let permissions = UInt32(LIBSSH2_SFTP_S_IFDIR) | 0o2755
        let directory = entry(type: .directory, permissions: permissions)
        let context = try #require(RemoteFilePermissionEditPolicy.context(for: directory))
        var draft = context.draft
        draft.set(false, capability: .read, for: .everyone)
        draft.set(false, capability: .execute, for: .everyone)

        // When the user applies a changed access draft.
        let requested = RemoteFilePermissionEditPolicy.requestedPermissions(
            draft: draft,
            context: context
        )

        // Then chmod keeps the original file-type and special bits intact.
        #expect(requested & UInt32(LIBSSH2_SFTP_S_IFMT) == UInt32(LIBSSH2_SFTP_S_IFDIR))
        #expect(requested & 0o7000 == 0o2000)
        #expect(requested & 0o777 == 0o750)
    }

    private func entry(
        type: RemoteFileType,
        permissions: UInt32?
    ) -> RemoteFileEntry {
        RemoteFileEntry(
            name: "item",
            path: "/tmp/item",
            type: type,
            size: nil,
            modifiedAt: nil,
            permissions: permissions,
            symlinkTarget: type == .symlink ? "/tmp/target" : nil
        )
    }
}
