import Foundation
import Testing
@testable import Waterm

// Test Context:
// These tests protect libssh2 SFTP status-code mapping after it moved out of
// SSHClient.swift. They use constants only and no SSH/SFTP session; update only
// when the Core SSH file-transfer error contract intentionally changes.

struct SSHRemoteFileErrorMapperTests {
    @Test
    func knownSFTPStatusCodesMapToSSHFileTransferErrors() {
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

        // Then common status codes map to stable Core SSH transfer errors.
        #expect(permission == .permissionDenied)
        #expect(missing == .pathNotFound)
        #expect(disconnected == .disconnected)
    }

    @Test
    func unknownSFTPStatusIncludesOperationPathAndRawStatusCode() {
        // When an unknown SFTP status is mapped.
        let error = SSHRemoteFileErrorMapper.remoteFileError(
            lastError: 999,
            operation: "download file",
            path: "/srv/archive.tar"
        )

        // Then the fallback error preserves the requested operation, path, and
        // raw status code from the libssh2 SFTP boundary.
        #expect(error == .failed(operation: "download file", path: "/srv/archive.tar", sftpStatusCode: 999))
    }
}
