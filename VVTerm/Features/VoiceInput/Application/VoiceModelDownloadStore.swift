import Foundation
import Combine

@MainActor
final class VoiceModelDownloadStore: ObservableObject {
    typealias DownloadAction = @MainActor @Sendable (MLXModelKind) async -> Void

    static let shared = VoiceModelDownloadStore(
        whisperManager: MLXModelManager(
            kind: .whisper,
            modelId: TranscriptionSettingsStore.currentWhisperModelId()
        ),
        parakeetManager: MLXModelManager(
            kind: .parakeetTDT,
            modelId: TranscriptionSettingsStore.currentParakeetModelId()
        )
    )

    let whisperManager: MLXModelManager
    let parakeetManager: MLXModelManager

    private let downloadAction: DownloadAction?
    private var downloadTasks: [MLXModelKind: (id: UUID, task: Task<Void, Never>)] = [:]

    private init(
        whisperManager: MLXModelManager,
        parakeetManager: MLXModelManager,
        downloadAction: DownloadAction? = nil
    ) {
        self.whisperManager = whisperManager
        self.parakeetManager = parakeetManager
        self.downloadAction = downloadAction
    }

    #if DEBUG
    static func makeForTesting(
        downloadAction: @escaping DownloadAction
    ) -> VoiceModelDownloadStore {
        VoiceModelDownloadStore(
            whisperManager: MLXModelManager(kind: .whisper, modelId: "test/whisper"),
            parakeetManager: MLXModelManager(kind: .parakeetTDT, modelId: "test/parakeet"),
            downloadAction: downloadAction
        )
    }
    #endif

    func manager(for kind: MLXModelKind) -> MLXModelManager {
        switch kind {
        case .whisper:
            return whisperManager
        case .parakeetTDT:
            return parakeetManager
        }
    }

    func refreshStatuses() {
        whisperManager.refreshStatus()
        parakeetManager.refreshStatus()
    }

    func setModelId(_ modelId: String, for kind: MLXModelKind) {
        let manager = manager(for: kind)
        manager.modelId = modelId
        manager.refreshStatus()
    }

    @discardableResult
    func downloadModel(for kind: MLXModelKind) -> Task<Void, Never> {
        if let task = downloadTasks[kind] {
            return task.task
        }

        let taskID = UUID()
        let task = Task { [downloadAction] in
            if let downloadAction {
                await downloadAction(kind)
            } else {
                await manager(for: kind).downloadModel()
            }
            clearDownloadTask(for: kind, id: taskID)
        }
        downloadTasks[kind] = (taskID, task)
        return task
    }

    func cancelDownload(for kind: MLXModelKind) {
        let task = downloadTasks.removeValue(forKey: kind)
        task?.task.cancel()
        manager(for: kind).cancelDownload()
    }

    func removeModel(for kind: MLXModelKind) {
        cancelDownload(for: kind)
        manager(for: kind).removeModel()
    }

    func clearAllStorage() {
        MLXModelManager.clearAllStorage()
        refreshStatuses()
    }

    private func clearDownloadTask(for kind: MLXModelKind, id: UUID) {
        guard downloadTasks[kind]?.id == id else { return }
        downloadTasks[kind] = nil
    }
}
