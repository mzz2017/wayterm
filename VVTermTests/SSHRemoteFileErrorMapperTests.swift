import Foundation
import Testing
@testable import VVTerm

// Test Context:
// These tests protect libssh2 SFTP status-code mapping after it moved out of
// SSHClient.swift. They use constants only and no SSH/SFTP session; update only
// when the RemoteFiles user-facing error contract intentionally changes.

struct SSHRemoteFileErrorMapperTests {
    @Test
    func knownSFTPStatusCodesMapToRemoteFileErrors() {
        // Given libssh2 SFTP status codes.
        let permission = SSHRemoteFileErrorMapper.remoteFileError(
            lastError: UInt(LIBSSH2_FX_PERMISSION_DENIED),
            operation: "read file",
            path: "/srv/secret"
        )
        let missing = SSHRemoteFileErrorMapper.remoteFileError(
            lastError: UInt(LIBSSH2_FX_NO_SUCH_FILE),
            operation: "read file",
            path: "/srv/missing"
        )
        let disconnected = SSHRemoteFileErrorMapper.remoteFileError(
            lastError: UInt(LIBSSH2_FX_CONNECTION_LOST),
            operation: "read file",
            path: "/srv/app"
        )

        // Then common status codes map to stable RemoteFiles domain errors.
        #expect(permission == .permissionDenied)
        #expect(missing == .pathNotFound)
        #expect(disconnected == .disconnected)
    }

    @Test
    func unknownSFTPStatusIncludesOperationAndPath() {
        // When an unknown SFTP status is mapped.
        let error = SSHRemoteFileErrorMapper.remoteFileError(
            lastError: 999,
            operation: "download file",
            path: "/srv/archive.tar"
        )

        // Then the fallback error remains actionable for the requested path.
        #expect(error == .failed("Failed to download file (/srv/archive.tar)."))
    }
}
