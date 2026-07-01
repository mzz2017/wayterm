import Foundation

extension RemoteFileBrowserStore {
    nonisolated func uploadAtomically(
        _ data: Data,
        to remotePath: String,
        permissions: Int32,
        strategy: SSHUploadStrategy = .automatic,
        using service: any RemoteFileService
    ) async throws {
        let temporaryRemotePath = makeAtomicRemoteUploadPath(for: remotePath)
        do {
            try await service.upload(data, to: temporaryRemotePath, permissions: permissions, strategy: strategy)
            try Task.checkCancellation()
            try await service.renameItem(at: temporaryRemotePath, to: remotePath)
        } catch {
            await removeAtomicUploadTemporaryFile(temporaryRemotePath, using: service)
            throw error
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
