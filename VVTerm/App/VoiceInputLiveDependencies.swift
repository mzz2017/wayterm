import Foundation

extension VoiceModelDownloadStore {
    static let shared = VoiceModelDownloadStore(settings: .live)
}

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
        let audioCaptureSession: any AudioCaptureSessionManaging
        #if os(iOS)
        audioCaptureSession = LiveAudioCaptureSession()
        #else
        audioCaptureSession = NoopAudioCaptureSession()
        #endif

        return AudioServiceDependencies(
            settings: .live,
            whisperProvider: MLXWhisperProvider.shared,
            parakeetProvider: MLXParakeetProvider.shared,
            isWhisperSupported: { MLXWhisperProvider.isSupported },
            isParakeetSupported: { MLXParakeetProvider.isSupported },
            isModelAvailable: { kind, modelId in
                MLXModelManager.isModelAvailable(kind: kind, modelId: modelId)
            },
            audioCaptureSession: audioCaptureSession
        )
    }
}
