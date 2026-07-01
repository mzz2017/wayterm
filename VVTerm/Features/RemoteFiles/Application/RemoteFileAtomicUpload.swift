import Foundation

enum RemoteFileAtomicPublishMode: Sendable {
    case replaceExisting
    case failIfDestinationExists
}

extension RemoteFileBrowserStore {
    nonisolated func uploadAtomically(
        _ data: Data,
        to remotePath: String,
        permissions: Int32,
        strategy: SSHUploadStrategy = .automatic,
        publishMode: RemoteFileAtomicPublishMode = .replaceExisting,
        using service: any RemoteFileService
    ) async throws {
        let temporaryRemotePath = makeAtomicRemoteUploadPath(for: remotePath)
        do {
            try await service.upload(data, to: temporaryRemotePath, permissions: permissions, strategy: strategy)
            try Task.checkCancellation()
            try await publishAtomicRemoteItem(
                at: temporaryRemotePath,
                to: remotePath,
                publishMode: publishMode,
                using: service
            )
        } catch {
            await removeAtomicUploadTemporaryFile(temporaryRemotePath, using: service)
            throw error
        }
    }

    nonisolated func publishAtomicRemoteItem(
        at temporaryRemotePath: String,
        to remotePath: String,
        publishMode: RemoteFileAtomicPublishMode,
        using service: any RemoteFileService
    ) async throws {
        switch publishMode {
        case .replaceExisting:
            try await service.renameItem(at: temporaryRemotePath, to: remotePath)
        case .failIfDestinationExists:
            try await service.renameItemIfDestinationMissing(at: temporaryRemotePath, to: remotePath)
        }
    }

    private nonisolated func removeAtomicUploadTemporaryFile(
        _ temporaryRemotePath: String,
        using service: any RemoteFileService
    ) async {
        let cleanupTask = Task.detached {
            try? await service.deleteFile(at: temporaryRemotePath)
        }
        await cleanupTask.value
    }

    private nonisolated func makeAtomicRemoteUploadPath(for remotePath: String) -> String {
        let normalizedPath = RemoteFilePath.normalize(remotePath)
        let parentPath = RemoteFilePath.parent(of: normalizedPath)
        let targetName = normalizedPath.split(separator: "/").last.map(String.init) ?? "upload"
        return RemoteFilePath.appending(
            ".\(targetName).vvterm-upload-\(UUID().uuidString).tmp",
            to: parentPath
        )
    }
}
