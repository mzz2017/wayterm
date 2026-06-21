import Foundation

enum TerminalRichPasteUploadRequestResult: Equatable, Sendable {
    case uploaded(remotePath: String, seededRemoteClipboard: Bool)
    case skippedNoConnection
    case cancelled
    case failed(String)
}

typealias TerminalRichPasteProgressHandler = @MainActor @Sendable (String?) async -> Void
typealias TerminalRichPastePathInputHandler = @MainActor @Sendable (String) async -> Void
typealias TerminalRichPasteUploadOperation = @MainActor @Sendable (
    ClipboardImagePayload,
    RichClipboardSettings,
    any RemoteConnectionLeaseClient,
    @escaping TerminalRichPasteProgressHandler
) async throws -> RichPasteUploadResult

@MainActor
enum TerminalRichPasteUploadRequest {
    static func perform(
        image: ClipboardImagePayload,
        settings: RichClipboardSettings,
        lease: RemoteConnectionLease?,
        upload: TerminalRichPasteUploadOperation,
        onProgress: @escaping TerminalRichPasteProgressHandler,
        pasteUploadedPath: @escaping TerminalRichPastePathInputHandler
    ) async -> TerminalRichPasteUploadRequestResult {
        guard let lease else {
            await onProgress(nil)
            return .skippedNoConnection
        }

        await onProgress(String(localized: "Uploading image to remote host..."))

        let uploadResult: Result<RichPasteUploadResult, Error>
        do {
            let result = try await lease.withExclusiveClient { client in
                let uploadResult = try await upload(image, settings, client, onProgress)
                try Task.checkCancellation()
                return uploadResult
            }
            uploadResult = .success(result)
        } catch {
            uploadResult = .failure(error)
        }

        await lease.close()
        await onProgress(nil)

        switch uploadResult {
        case .success(let result):
            await pasteUploadedPath(RemoteTerminalBootstrap.posixPastedPath(result.remotePath))
            return .uploaded(
                remotePath: result.remotePath,
                seededRemoteClipboard: result.seededRemoteClipboard
            )
        case .failure(let error) where error is CancellationError:
            return .cancelled
        case .failure(let error):
            return .failed(error.localizedDescription)
        }
    }
}
