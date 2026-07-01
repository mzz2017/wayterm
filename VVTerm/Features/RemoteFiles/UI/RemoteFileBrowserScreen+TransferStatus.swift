import SwiftUI

#if os(macOS)
import AppKit
#endif

extension RemoteFileBrowserScreen {
    @MainActor
    func beginTransferStatus(
        id: UUID,
        title: String,
        message: String,
        completedUnitCount: Int? = nil,
        totalUnitCount: Int? = nil,
        fileURL: URL? = nil,
        fileName: String? = nil,
        filePath: String? = nil
    ) {
        showNotice(
            NoticeItem(
                id: id.uuidString,
                lane: .bottomOperation,
                level: .info,
                leading: .activity,
                title: title,
                message: message,
                detail: transferDetail(fileName: fileName, filePath: filePath),
                progress: transferProgress(
                    completedUnitCount: completedUnitCount,
                    totalUnitCount: totalUnitCount
                ),
                action: transferCompletionAction(fileURL: fileURL),
                dismissAction: { dismissNotice(id: id.uuidString) }
            )
        )
    }

    @MainActor
    func updateTransferStatus(
        id: UUID,
        title: String,
        message: String,
        completedUnitCount: Int,
        totalUnitCount: Int
    ) {
        showNotice(
            NoticeItem(
                id: id.uuidString,
                lane: .bottomOperation,
                level: .info,
                leading: .activity,
                title: title,
                message: message,
                progress: NoticeProgress(
                    completedUnitCount: completedUnitCount,
                    totalUnitCount: totalUnitCount
                ),
                dismissAction: { dismissNotice(id: id.uuidString) }
            )
        )
    }

    @MainActor
    func completeTransferStatus(
        id: UUID,
        title: String,
        message: String,
        fileURL: URL? = nil,
        fileName: String? = nil,
        filePath: String? = nil
    ) {
        showNotice(
            NoticeItem(
                id: id.uuidString,
                lane: .bottomOperation,
                level: .success,
                leading: .icon("checkmark.circle.fill"),
                title: title,
                message: message,
                detail: transferDetail(fileName: fileName, filePath: filePath),
                lifetime: .autoDismiss(.seconds(2)),
                action: transferCompletionAction(fileURL: fileURL)
            )
        )
    }

    func transferProgress(
        completedUnitCount: Int?,
        totalUnitCount: Int?
    ) -> NoticeProgress? {
        guard let completedUnitCount, let totalUnitCount else { return nil }
        return NoticeProgress(
            completedUnitCount: completedUnitCount,
            totalUnitCount: totalUnitCount
        )
    }

    func transferDetail(fileName: String?, filePath: String?) -> String? {
        if let filePath, !filePath.isEmpty {
            return filePath
        }

        if let fileName, !fileName.isEmpty {
            return fileName
        }

        return nil
    }

    func transferCompletionAction(fileURL: URL?) -> NoticeAction? {
        #if os(macOS)
        guard let fileURL else { return nil }

        return NoticeAction(id: "show-in-finder", title: String(localized: "Show in Finder")) {
            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
        }
        #else
        return nil
        #endif
    }

    func performTransfer(
        title: String,
        initialMessage: String,
        successMessage: String,
        successFileURL: URL? = nil,
        successFileName: String? = nil,
        successFilePath: String? = nil,
        operation: @escaping @Sendable (
            @escaping RemoteFileBrowserStore.TransferProgressPublisher,
            @escaping RemoteFileBrowserStore.TransferServerScopeBinder
        ) async throws -> Void
    ) {
        let transferID = UUID()

        withAnimation(.easeInOut(duration: 0.2)) {
            beginTransferStatus(
                id: transferID,
                title: title,
                message: initialMessage
            )
        }

        browser.requestTransfer(
            serverIds: [server.id],
            operation: operation,
            onProgress: { progress in
                let itemName = progress.currentItemName.isEmpty
                    ? String(localized: "item")
                    : progress.currentItemName
                updateTransferStatus(
                    id: transferID,
                    title: title,
                    message: String(
                        format: String(localized: "%lld of %lld: %@"),
                        Int64(progress.completedUnitCount),
                        Int64(progress.totalUnitCount),
                        itemName
                    ),
                    completedUnitCount: progress.completedUnitCount,
                    totalUnitCount: progress.totalUnitCount
                )
            },
            onSuccess: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    completeTransferStatus(
                        id: transferID,
                        title: title,
                        message: successMessage,
                        fileURL: successFileURL,
                        fileName: successFileName,
                        filePath: successFilePath
                    )
                }
            },
            onFailure: { error in
                showNotice(
                    NoticeItem(
                        id: transferID.uuidString,
                        lane: .bottomOperation,
                        level: .error,
                        leading: .icon("xmark.octagon.fill"),
                        title: title,
                        message: remoteOperationErrorMessage(for: error),
                        dismissAction: { dismissNotice(id: transferID.uuidString) }
                    )
                )
            }
        )
    }

    func performTransfer(
        title: String,
        initialMessage: String,
        successMessage: String,
        successFileURL: URL? = nil,
        successFileName: String? = nil,
        successFilePath: String? = nil,
        operation: @escaping @Sendable (
            @escaping RemoteFileBrowserStore.TransferProgressPublisher
        ) async throws -> Void
    ) {
        performTransfer(
            title: title,
            initialMessage: initialMessage,
            successMessage: successMessage,
            successFileURL: successFileURL,
            successFileName: successFileName,
            successFilePath: successFilePath
        ) { onProgress, _ in
            try await operation(onProgress)
        }
    }

    func performTransfer(
        title: String,
        initialMessage: String,
        successMessage: String,
        successFileURL: URL? = nil,
        successFileName: String? = nil,
        successFilePath: String? = nil,
        operation: @escaping @Sendable () async throws -> Void
    ) {
        performTransfer(
            title: title,
            initialMessage: initialMessage,
            successMessage: successMessage,
            successFileURL: successFileURL,
            successFileName: successFileName,
            successFilePath: successFilePath
        ) { _ in
            try await operation()
        }
    }
}
