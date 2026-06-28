//
//  SSHRemoteFileErrorMapper.swift
//  VVTerm
//
//  Maps libssh2 SFTP status codes into RemoteFiles domain errors.
//

import Foundation

enum SSHRemoteFileErrorMapper {
    nonisolated static func remoteFileError(
        lastError: UInt,
        operation: String,
        path: String?
    ) -> SSHFileTransferError {
        switch lastError {
        case UInt(LIBSSH2_FX_PERMISSION_DENIED):
            return .permissionDenied
        case UInt(LIBSSH2_FX_NO_SUCH_FILE), UInt(LIBSSH2_FX_NO_SUCH_PATH):
            return .pathNotFound
        case UInt(LIBSSH2_FX_NO_CONNECTION), UInt(LIBSSH2_FX_CONNECTION_LOST):
            return .disconnected
        case UInt(LIBSSH2_FX_NOT_A_DIRECTORY):
            return .notDirectory
        case UInt(LIBSSH2_FX_LINK_LOOP):
            return .linkLoop
        default:
            return .failed(operation: operation, path: path)
        }
    }
}
