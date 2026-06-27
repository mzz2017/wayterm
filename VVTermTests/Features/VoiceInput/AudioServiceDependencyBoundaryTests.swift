import Foundation
import Testing
@testable import VVTerm

// Test Context:
// These tests protect VoiceInput runtime dependency boundaries. AudioService
// owns recording lifecycle coordination, but provider selection and MLX model
// availability must be supplied through injected dependencies so tests can
// exercise lifecycle decisions without loading real models or reading global
// transcription settings. Update this test only if the audio runtime ownership
// boundary intentionally changes.
@MainActor
struct AudioServiceDependencyBoundaryTests {
    @Test
    func providerResolutionUsesInjectedSettingsAndAvailability() {
        let unavailableWhisper = AudioService(
            dependencies: makeDependencies(
                provider: .mlxWhisper,
                isWhisperSupported: true,
                availableModels: [:]
            )
        )
        let availableWhisper = AudioService(
            dependencies: makeDependencies(
                provider: .mlxWhisper,
                isWhisperSupported: true,
                availableModels: [.whisper: "test/whisper"]
            )
        )
        let unsupportedParakeet = AudioService(
            dependencies: makeDependencies(
                provider: .mlxParakeet,
                isParakeetSupported: false,
                availableModels: [.parakeetTDT: "test/parakeet"]
            )
        )

        #expect(
            unavailableWhisper.resolveProviderForTesting() == .system,
            "Missing injected Whisper model availability should fall back to system speech."
        )
        #expect(
            availableWhisper.resolveProviderForTesting() == .mlxWhisper,
            "Available injected Whisper support and model should keep MLX Whisper selected."
        )
        #expect(
            unsupportedParakeet.resolveProviderForTesting() == .system,
            "Unsupported injected Parakeet runtime should fall back to system speech."
        )
    }

    @Test
    func audioRuntimeDoesNotReadGlobalVoiceSettingsOrProvidersDirectly() throws {
        let root = try sourceRoot()
        let voiceInput = root.appendingPathComponent("VVTerm/Features/VoiceInput")
        let audioService = try source(
            at: voiceInput.appendingPathComponent("Infrastructure/AudioService.swift")
        )
        let whisperProvider = try source(
            at: voiceInput.appendingPathComponent("Infrastructure/Whisper/MLXWhisperProvider.swift")
        )
        let parakeetProvider = try source(
            at: voiceInput.appendingPathComponent("Infrastructure/Parakeet/MLXParakeetProvider.swift")
        )
        let speechRecognitionService = try source(
            at: voiceInput.appendingPathComponent("Infrastructure/SpeechRecognitionService.swift")
        )
        let audioCaptureService = try source(
            at: voiceInput.appendingPathComponent("Infrastructure/AudioCaptureService.swift")
        )
        let modelManager = try source(
            at: voiceInput.appendingPathComponent("Infrastructure/MLXModelManager.swift")
        )
        let modelSizeCache = try source(
            at: voiceInput.appendingPathComponent("Infrastructure/MLXModelSizeCache.swift")
        )
        let liveModelInfoFetcher = try source(
            at: voiceInput.appendingPathComponent("Infrastructure/LiveMLXModelInfoFetcher.swift")
        )
        let liveDependencies = try source(
            at: root.appendingPathComponent("VVTerm/App/VoiceInputLiveDependencies.swift")
        )
        let modelDownloadStore = try source(
            at: voiceInput.appendingPathComponent("Application/VoiceModelDownloadStore.swift")
        )

        #expect(
            !audioService.contains("TranscriptionSettingsStore.current"),
            "AudioService should receive voice settings through TranscriptionSettingsReader injection."
        )
        #expect(
            !audioService.contains("private let mlxWhisperProvider = MLXWhisperProvider.shared"),
            "AudioService should receive Whisper provider through injected runtime dependencies."
        )
        #expect(
            !audioService.contains("private let mlxParakeetProvider = MLXParakeetProvider.shared"),
            "AudioService should receive Parakeet provider through injected runtime dependencies."
        )
        #expect(
            !whisperProvider.contains("TranscriptionSettingsStore.current"),
            "MLXWhisperProvider should read settings through its injected TranscriptionSettingsReader."
        )
        #expect(
            !parakeetProvider.contains("TranscriptionSettingsStore.current"),
            "MLXParakeetProvider should read settings through its injected TranscriptionSettingsReader."
        )
        #expect(
            !speechRecognitionService.contains("TranscriptionSettingsStore.current"),
            "SpeechRecognitionService should read language settings through its injected TranscriptionSettingsReader."
        )
        #expect(
            !modelDownloadStore.contains("TranscriptionSettingsStore.current"),
            "VoiceModelDownloadStore should receive model IDs through injected settings instead of reading global defaults."
        )
        #expect(
            !modelDownloadStore.contains("MLXModelSizeCache.shared"),
            "VoiceModelDownloadStore should receive model size lookup through App live dependencies."
        )
        #expect(
            !modelManager.contains("MLXModelSizeCache.shared"),
            "MLXModelManager should receive model size lookup through injected dependencies."
        )
        #expect(
            !modelSizeCache.contains("URLSession.shared"),
            "MLXModelSizeCache should receive repository metadata through an injected fetcher."
        )
        #expect(
            liveModelInfoFetcher.contains("URLSession.shared.data"),
            "Live MLX model metadata fetching should be isolated to the live URLSession adapter."
        )
        #expect(
            liveDependencies.contains("modelSizeProvider: MLXModelSizeCache.shared"),
            "App live VoiceInput dependencies should provide the shared model size cache."
        )
        #expect(
            !audioCaptureService.contains("AVAudioSession.sharedInstance()"),
            "AudioCaptureService should receive audio session lifecycle through AudioCaptureSessionManaging injection."
        )
        #expect(
            !audioCaptureService.contains("try?"),
            "AudioCaptureService should not silently swallow audio session lifecycle failures."
        )
        #expect(
            audioCaptureService.contains("func activateForRecording() throws"),
            "VoiceInput should model audio session activation as a throwing lifecycle service."
        )
        #expect(
            audioCaptureService.contains("lastSessionDeactivationError"),
            "AudioCaptureService should preserve audio session deactivation failure diagnostics."
        )
        #expect(
            liveDependencies.contains("audioCaptureSession = LiveAudioCaptureSession()")
                && liveDependencies.contains("audioCaptureSession: audioCaptureSession"),
            "App live VoiceInput dependencies should provide the iOS audio session lifecycle service."
        )
    }

    private func makeDependencies(
        provider: TranscriptionProvider,
        isWhisperSupported: Bool = false,
        isParakeetSupported: Bool = false,
        availableModels: [MLXModelKind: String] = [:]
    ) -> AudioServiceDependencies {
        AudioServiceDependencies(
            settings: TranscriptionSettingsReader {
                TranscriptionSettingsSnapshot(
                    provider: provider,
                    whisperModelId: "test/whisper",
                    parakeetModelId: "test/parakeet",
                    languageCode: "en"
                )
            },
            whisperProvider: FakeVoiceSampleTranscriber(),
            parakeetProvider: FakeVoiceSampleTranscriber(),
            isWhisperSupported: { isWhisperSupported },
            isParakeetSupported: { isParakeetSupported },
            isModelAvailable: { kind, modelId in
                availableModels[kind] == modelId
            },
            audioCaptureSession: NoopAudioCaptureSession()
        )
    }

    private func source(at url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    private func sourceRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.lastPathComponent != "VVTermTests" {
            let next = url.deletingLastPathComponent()
            if next.path == url.path {
                throw SourceRootError.notFound
            }
            url = next
        }
        return url.deletingLastPathComponent()
    }

    private enum SourceRootError: Error {
        case notFound
    }
}

private final class FakeVoiceSampleTranscriber: VoiceSampleTranscribing {
    func transcribe(samples: [Float]) async throws -> String {
        ""
    }
}
