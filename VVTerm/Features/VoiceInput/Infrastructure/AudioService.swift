import Foundation
import Combine
import os.log

protocol VoiceSampleTranscribing: AnyObject {
    func transcribe(samples: [Float]) async throws -> String
}

extension MLXWhisperProvider: VoiceSampleTranscribing {}
extension MLXParakeetProvider: VoiceSampleTranscribing {}

struct AudioServiceDependencies {
    var settings: TranscriptionSettingsReader
    var whisperProvider: any VoiceSampleTranscribing
    var parakeetProvider: any VoiceSampleTranscribing
    var isWhisperSupported: @MainActor () -> Bool
    var isParakeetSupported: @MainActor () -> Bool
    var isModelAvailable: @MainActor (MLXModelKind, String) -> Bool
    var audioCaptureSession: any AudioCaptureSessionManaging
    var audioCaptureService: (any VoiceAudioCapturing)? = nil
    var appleSpeechFallback: (@MainActor ([Float], Double) async -> String?)? = nil
    var checkPermissions: (@MainActor (Bool) async -> Bool)? = nil
    var requestPermissions: (@MainActor (Bool) async -> Bool)? = nil
}

@MainActor
class AudioService: NSObject, ObservableObject {
    private let logger = Logger.audio
    @Published var isRecording = false
    @Published var transcribedText = ""
    @Published var partialTranscription = ""
    @Published var audioLevel: Float = 0.0
    @Published var recordingDuration: TimeInterval = 0
    @Published var permissionStatus: AudioPermissionManager.PermissionStatus = .notDetermined

    // Services
    private let permissionManager = AudioPermissionManager()
    private let speechRecognitionService: SpeechRecognitionService
    private let audioCaptureService: any VoiceAudioCapturing
    private let dependencies: AudioServiceDependencies

    private var activeProvider: TranscriptionProvider = .system

    init(dependencies: AudioServiceDependencies? = nil) {
        let resolvedDependencies = dependencies ?? .live
        self.dependencies = resolvedDependencies
        self.speechRecognitionService = SpeechRecognitionService(settings: resolvedDependencies.settings)
        self.audioCaptureService = resolvedDependencies.audioCaptureService
            ?? AudioCaptureService(audioSession: resolvedDependencies.audioCaptureSession)
        super.init()
        setupBindings()
    }

    // MARK: - Setup

    private func setupBindings() {
        // Permission status
        permissionManager.$permissionStatus
            .assign(to: &$permissionStatus)

        // Speech recognition
        speechRecognitionService.$transcribedText
            .assign(to: &$transcribedText)

        speechRecognitionService.$partialTranscription
            .assign(to: &$partialTranscription)

        // Audio capture
        if let observableAudioCaptureService = audioCaptureService as? AudioCaptureService {
            observableAudioCaptureService.$audioLevel
                .assign(to: &$audioLevel)

            observableAudioCaptureService.$recordingDuration
                .assign(to: &$recordingDuration)
        }
    }

    // MARK: - Permission Handling

    func requestPermissions(includeSpeech: Bool) async -> Bool {
        if let requestPermissions = dependencies.requestPermissions {
            return await requestPermissions(includeSpeech)
        }
        return await permissionManager.requestPermissions(includeSpeech: includeSpeech)
    }

    func checkPermissions(includeSpeech: Bool) async -> Bool {
        if let checkPermissions = dependencies.checkPermissions {
            return await checkPermissions(includeSpeech)
        }
        return await permissionManager.checkPermissions(includeSpeech: includeSpeech)
    }

    // MARK: - Recording Control

    func startRecording() async throws {
        let settings = dependencies.settings.current()
        let requestedProvider = settings.provider
        let effectiveProvider = resolveProvider(for: requestedProvider, settings: settings)
        if requestedProvider == .mlxWhisper && effectiveProvider == .system {
            logger.warning("MLX Whisper not available; falling back to Apple Speech")
        } else if requestedProvider == .mlxParakeet && effectiveProvider == .system {
            logger.warning("MLX Parakeet not available; falling back to Apple Speech")
        }
        activeProvider = effectiveProvider

        let needsSpeech = effectiveProvider == .system
        let hasPermissions = await checkPermissions(includeSpeech: needsSpeech)
        if !hasPermissions {
            let granted = await requestPermissions(includeSpeech: needsSpeech)
            guard granted else {
                throw RecordingError.permissionDenied
            }
        }

        // Reset state
        speechRecognitionService.resetTranscriptions()
        await audioCaptureService.cancel()

        // Start services
        switch effectiveProvider {
        case .system:
            try await startAppleSpeech()
        case .mlxWhisper, .mlxParakeet:
            try startMLXCapture()
        }

        isRecording = true
    }

    func stopRecording() async -> String {
        isRecording = false

        let samples = await audioCaptureService.stop()

        switch activeProvider {
        case .system:
            let finalText = await speechRecognitionService.stopRecognition()
            speechRecognitionService.resetTranscriptions()
            return finalText
        case .mlxWhisper:
            do {
                let text = try await dependencies.whisperProvider.transcribe(samples: samples)
                transcribedText = text
                return text
            } catch is CancellationError {
                return ""
            } catch {
                logger.error("MLX Whisper failed: \(error.localizedDescription)")
                if let fallback = await fallbackToAppleSpeech(samples: samples) {
                    transcribedText = fallback
                    return fallback
                }
                return ""
            }
        case .mlxParakeet:
            do {
                let text = try await dependencies.parakeetProvider.transcribe(samples: samples)
                transcribedText = text
                return text
            } catch is CancellationError {
                return ""
            } catch {
                logger.error("MLX Parakeet failed: \(error.localizedDescription)")
                if let fallback = await fallbackToAppleSpeech(samples: samples) {
                    transcribedText = fallback
                    return fallback
                }
                return ""
            }
        }
    }

    func cancelRecording() async {
        isRecording = false

        await audioCaptureService.cancel()
        speechRecognitionService.cancelRecognition()
        speechRecognitionService.resetTranscriptions()
        transcribedText = ""
        partialTranscription = ""
    }

    // MARK: - Errors

    enum RecordingError: LocalizedError {
        case permissionDenied
        case speechRecognitionUnavailable
        case recordingFailed
        case mlxUnavailable

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return String(localized: "Microphone permission is required. The microphone will be automatically requested when recording starts.")
            case .speechRecognitionUnavailable:
                return String(localized: "Speech recognition is not available. Please enable Siri in System Settings > Siri & Spotlight.")
            case .recordingFailed:
                return String(localized: "Failed to start recording. Please check microphone permissions in System Settings > Privacy & Security > Microphone.")
            case .mlxUnavailable:
                return String(localized: "MLX transcription is not available on this Mac. Switching to Apple Speech.")
            }
        }
    }

    // MARK: - Provider Resolution

    private func resolveProvider(
        for requested: TranscriptionProvider,
        settings: TranscriptionSettingsSnapshot
    ) -> TranscriptionProvider {
        switch requested {
        case .system:
            return .system
        case .mlxWhisper:
            guard dependencies.isWhisperSupported() else { return .system }
            guard dependencies.isModelAvailable(.whisper, settings.whisperModelId) else { return .system }
            return .mlxWhisper
        case .mlxParakeet:
            guard dependencies.isParakeetSupported() else { return .system }
            guard dependencies.isModelAvailable(.parakeetTDT, settings.parakeetModelId) else { return .system }
            return .mlxParakeet
        }
    }

    #if DEBUG
    func resolveProviderForTesting() -> TranscriptionProvider {
        let settings = dependencies.settings.current()
        return resolveProvider(for: settings.provider, settings: settings)
    }
    #endif

    // MARK: - Apple Speech

    private func startAppleSpeech() async throws {
        guard speechRecognitionService.isAvailable else {
            throw RecordingError.speechRecognitionUnavailable
        }

        audioCaptureService.bufferHandler = { [weak speechRecognitionService] buffer in
            speechRecognitionService?.appendAudioBuffer(buffer)
        }

        try await speechRecognitionService.startRecognition()
        do {
            try audioCaptureService.start()
        } catch {
            throw RecordingError.recordingFailed
        }
    }

    // MARK: - MLX

    private func startMLXCapture() throws {
        audioCaptureService.bufferHandler = nil
        do {
            try audioCaptureService.start()
        } catch {
            throw RecordingError.recordingFailed
        }
    }

    private func fallbackToAppleSpeech(samples: [Float]) async -> String? {
        guard !samples.isEmpty else { return nil }

        if let appleSpeechFallback = dependencies.appleSpeechFallback {
            return await appleSpeechFallback(samples, audioCaptureService.sampleRate)
        }

        guard speechRecognitionService.isAvailable else { return nil }

        let hasPermissions = await checkPermissions(includeSpeech: true)
        if !hasPermissions {
            let granted = await requestPermissions(includeSpeech: true)
            guard granted else { return nil }
        }

        do {
            let text = try await speechRecognitionService.transcribe(
                samples: samples,
                sampleRate: audioCaptureService.sampleRate
            )
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            logger.error("Apple Speech fallback failed: \(error.localizedDescription)")
            return nil
        }
    }
}
