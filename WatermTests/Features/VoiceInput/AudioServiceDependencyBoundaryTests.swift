import Foundation
import AVFoundation
import Testing
@testable import Waterm

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
    func mlxStopCancellationDoesNotFallbackToAppleSpeech() async throws {
        let whisper = FakeVoiceSampleTranscriber()
        whisper.error = CancellationError()
        let capture = FakeVoiceAudioCapture(stopSamples: [0.25, -0.25])
        var fallbackCalls = 0
        let service = AudioService(
            dependencies: makeDependencies(
                provider: .mlxWhisper,
                isWhisperSupported: true,
                availableModels: [.whisper: "test/whisper"],
                whisperProvider: whisper,
                audioCaptureService: capture,
                appleSpeechFallback: { _, _ in
                    fallbackCalls += 1
                    return "fallback command"
                }
            )
        )

        // Given the VoiceInput lifecycle starts with MLX Whisper as the
        // effective provider and then cancellation reaches the transcriber.
        try await service.startRecording()
        #expect(capture.startCalls == 1, "MLX voice recording should start the injected audio capture service.")

        let text = await service.stopRecording()

        // Then cancellation is lifecycle completion, not an MLX failure that
        // should start Apple Speech fallback and publish stale command text.
        #expect(text.isEmpty, "Canceled MLX stop should not return Apple Speech fallback text.")
        #expect(fallbackCalls == 0, "Canceled MLX stop must not invoke Apple Speech fallback.")
        #expect(service.transcribedText.isEmpty, "Canceled MLX stop must not publish fallback transcription text.")
    }

    @Test
    func audioBufferUpdateRegistryTracksMainActorUpdatesUntilCompletion() async {
        let registry = AudioBufferUpdateTaskRegistry()
        let gate = AudioBufferUpdateGate()

        // When an audio tap callback queues a main-actor buffer update.
        registry.track {
            await gate.wait()
        }

        // Then the task is visible immediately, so AudioCaptureService.stop()
        // can wait for already-queued sample updates before returning samples
        // for transcription.
        #expect(registry.tasks().count == 1, "Audio buffer update should be published before track returns.")

        // And completing the update removes it from the registry.
        await gate.open()
        for _ in 0..<20 where !registry.tasks().isEmpty {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(registry.tasks().isEmpty, "Audio buffer update registry should remove completed tasks.")
    }

    @Test
    func audioRuntimeDoesNotReadGlobalVoiceSettingsOrProvidersDirectly() throws {
        let root = try sourceRoot()
        let voiceInput = root.appendingPathComponent("Waterm/Features/VoiceInput")
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
            at: root.appendingPathComponent("Waterm/App/VoiceInputLiveDependencies.swift")
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
            audioCaptureService.contains("await waitForBufferUpdateTasks()"),
            "AudioCaptureService stop/cancel should await queued buffer updates before returning samples."
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
        availableModels: [MLXModelKind: String] = [:],
        whisperProvider: (any VoiceSampleTranscribing)? = nil,
        parakeetProvider: (any VoiceSampleTranscribing)? = nil,
        audioCaptureService: (any VoiceAudioCapturing)? = nil,
        appleSpeechFallback: (@MainActor ([Float], Double) async -> String?)? = nil
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
            whisperProvider: whisperProvider ?? FakeVoiceSampleTranscriber(),
            parakeetProvider: parakeetProvider ?? FakeVoiceSampleTranscriber(),
            isWhisperSupported: { isWhisperSupported },
            isParakeetSupported: { isParakeetSupported },
            isModelAvailable: { kind, modelId in
                availableModels[kind] == modelId
            },
            audioCaptureSession: NoopAudioCaptureSession(),
            audioCaptureService: audioCaptureService,
            appleSpeechFallback: appleSpeechFallback,
            checkPermissions: { _ in true },
            requestPermissions: { _ in true }
        )
    }

    private func source(at url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    private func sourceRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.lastPathComponent != "WatermTests" {
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

@MainActor
private final class FakeVoiceSampleTranscriber: VoiceSampleTranscribing {
    var error: Error?

    func transcribe(samples: [Float]) async throws -> String {
        if let error {
            throw error
        }
        return ""
    }
}

@MainActor
private final class FakeVoiceAudioCapture: VoiceAudioCapturing {
    var audioLevel: Float = 0
    var recordingDuration: TimeInterval = 0
    var sampleRate: Double = 16_000
    var bufferHandler: ((AVAudioPCMBuffer) -> Void)?
    private(set) var startCalls = 0
    private let stopSamples: [Float]

    init(stopSamples: [Float]) {
        self.stopSamples = stopSamples
    }

    func start() throws {
        startCalls += 1
    }

    func stop() async -> [Float] {
        stopSamples
    }

    func cancel() async {}
}

private actor AudioBufferUpdateGate {
    private var isOpen = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let pending = continuations
        continuations.removeAll()
        pending.forEach { $0.resume() }
    }
}
