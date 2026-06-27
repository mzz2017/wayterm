import Foundation

extension TranscriptionSettingsReader {
    static var live: TranscriptionSettingsReader {
        TranscriptionSettingsReader {
            TranscriptionSettingsSnapshot(
                provider: TranscriptionSettingsStore.currentProvider(),
                whisperModelId: TranscriptionSettingsStore.currentWhisperModelId(),
                parakeetModelId: TranscriptionSettingsStore.currentParakeetModelId(),
                languageCode: TranscriptionSettingsStore.currentLanguageCode()
            )
        }
    }
}

extension AudioServiceDependencies {
    static var live: AudioServiceDependencies {
        AudioServiceDependencies(
            settings: .live,
            whisperProvider: MLXWhisperProvider.shared,
            parakeetProvider: MLXParakeetProvider.shared,
            isWhisperSupported: { MLXWhisperProvider.isSupported },
            isParakeetSupported: { MLXParakeetProvider.isSupported },
            isModelAvailable: { kind, modelId in
                MLXModelManager.isModelAvailable(kind: kind, modelId: modelId)
            }
        )
    }
}
