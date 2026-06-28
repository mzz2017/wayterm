import Foundation
import Combine

@MainActor
final class VoiceModelDownloadStore: ObservableObject {
    typealias DownloadAction = @MainActor @Sendable (MLXModelKind) async -> Void

    let whisperManager: MLXModelManager
    let parakeetManager: MLXModelManager

    private let downloadAction: DownloadAction?
    private var downloadTasks: [MLXModelKind: (id: UUID, task: Task<Void, Never>)] = [:]

    init(
        settings: TranscriptionSettingsReader,
        downloadAction: DownloadAction? = nil,
        modelSizeProvider: any MLXModelSizing = NoopMLXModelSizer()
    ) {
        let snapshot = settings.current()
        self.whisperManager = MLXModelManager(
            kind: .whisper,
            modelId: snapshot.whisperModelId,
            modelSizeProvider: modelSizeProvider
        )
        self.parakeetManager = MLXModelManager(
            kind: .parakeetTDT,
            modelId: snapshot.parakeetModelId,
            modelSizeProvider: modelSizeProvider
        )
        self.downloadAction = downloadAction
    }

    deinit {
        // Store lifetime is MainActor-bound; keep teardown synchronous instead of spawning untracked cleanup work.
        MainActor.assumeIsolated {
            cancelTrackedDownloads()
            whisperManager.cleanup()
            parakeetManager.cleanup()
        }
    }

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
        let manager = manager(for: kind)
        let task = Task { [weak self, downloadAction, manager] in
            if let downloadAction {
                await downloadAction(kind)
            } else {
                await manager.downloadModel()
            }
            self?.clearDownloadTask(for: kind, id: taskID)
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

    private func cancelTrackedDownloads() {
        for (_, task) in downloadTasks.values {
            task.cancel()
        }
        downloadTasks.removeAll()
    }

    private func clearDownloadTask(for kind: MLXModelKind, id: UUID) {
        guard downloadTasks[kind]?.id == id else { return }
        downloadTasks[kind] = nil
    }
}
