import Foundation
import Testing
@testable import Waterm

// Test Context:
// These tests protect remote-file permission parsing and display rules. They use
// pure permission fixtures and no SFTP calls; update only when permission
// semantics intentionally change.

struct RemoteFilePermissionTests {
    @Test
    func draftUpdatesBitsAndSummaries() {
        var draft = RemoteFilePermissionDraft(accessBits: 0o640)
        draft.set(true, capability: .execute, for: .owner)
        draft.set(false, capability: .read, for: .group)

        #expect(draft.accessBits == 0o700)
        #expect(draft.octalSummary == "700")
        #expect(draft.symbolicSummary == "rwx------")
    }

    @Test
    func capabilityBitMappingMatchesExpectedAudienceMasks() {
        #expect(RemoteFilePermissionCapability.read.bit(for: .owner) == UInt32(LIBSSH2_SFTP_S_IRUSR))
        #expect(RemoteFilePermissionCapability.write.bit(for: .group) == UInt32(LIBSSH2_SFTP_S_IWGRP))
        #expect(RemoteFilePermissionCapability.execute.bit(for: .everyone) == UInt32(LIBSSH2_SFTP_S_IXOTH))
    }
}
