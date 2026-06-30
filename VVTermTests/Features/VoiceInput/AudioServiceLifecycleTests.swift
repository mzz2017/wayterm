import AVFoundation
import Foundation
import Speech
import Testing
@testable import VVTerm

// Test Context:
// These tests protect VoiceInput start-failure rollback. AudioService may start
// Apple Speech before the microphone capture service starts, and
// AudioCaptureService may activate the platform audio session before AVAudioEngine
// starts. Failure in either half-started path must release the owned runtime
// resources before returning an error. Fakes avoid real microphone, Speech, and
// model access while preserving the start/cancel ordering being tested.
@MainActor
struct AudioServiceLifecycleTests {
    @Test
    func appleSpeechStartFailureCancelsStartedSpeechAndCapture() async throws {
        let speechRunner = RecordingSpeechAudioRecognitionRunner()
        let capture = FailingStartVoiceAudioCapture()
        let service = AudioService(
            dependencies: makeDependencies(
                audioCaptureService: capture,
                speechAudioRecognitionRunner: speechRunner
            )
        )

        // Given Apple Speech starts successfully but audio capture fails while
        // starting the microphone runtime.
        do {
            try await service.startRecording()
            Issue.record("Expected system voice recording start to fail after capture start failure.")
        } catch AudioService.RecordingError.recordingFailed {
            // Expected.
        }

        // Then the half-started Speech task and capture runtime must be rolled
        // back before startRecording returns.
        #expect(speechRunner.task.didCancel, "AudioService should cancel started Apple Speech after capture start fails.")
        #expect(capture.cancelCalls == 2, "AudioService should cancel capture during reset and again during failed-start rollback.")
        #expect(capture.bufferHandler == nil, "AudioService should clear the Speech buffer handler after failed start rollback.")
        #expect(!service.isRecording, "Failed start must not publish an active recording state.")
    }

    @Test
    func audioCaptureStartFailureDeactivatesActivatedSession() throws {
        let session = RecordingAudioCaptureSession()
        let engine = FailingStartVoiceAudioEngine()
        let service = AudioCaptureService(
            audioSession: session,
            makeEngine: { engine }
        )

        // When AVAudioEngine fails after the audio session was activated.
        do {
            try service.start()
            Issue.record("Expected audio capture start to fail after session activation.")
        } catch AudioServiceLifecycleTestError.engineStartFailed {
            // Expected.
        }

        // Then the platform audio session must be released even though
        // isRecording was never set to true.
        #expect(session.activateCalls == 1, "AudioCaptureService should activate the audio session before starting the engine.")
        #expect(session.deactivateCalls == 1, "AudioCaptureService should roll back the activated audio session when engine start fails.")
        #expect(engine.didRemoveTap, "AudioCaptureService should remove the installed tap when start fails.")
        #expect(engine.didStop, "AudioCaptureService should stop the engine when start fails.")
        #expect(service.audioLevel == 0)
        #expect(service.recordingDuration == 0)
    }

    private func makeDependencies(
        audioCaptureService: any VoiceAudioCapturing,
        speechAudioRecognitionRunner: any SpeechAudioRecognitionRunning
    ) -> AudioServiceDependencies {
        AudioServiceDependencies(
            settings: TranscriptionSettingsReader {
                TranscriptionSettingsSnapshot(
                    provider: .system,
                    whisperModelId: "test/whisper",
                    parakeetModelId: "test/parakeet",
                    languageCode: "en"
                )
            },
            whisperProvider: RecordingVoiceSampleTranscriber(),
            parakeetProvider: RecordingVoiceSampleTranscriber(),
            isWhisperSupported: { false },
            isParakeetSupported: { false },
            isModelAvailable: { _, _ in false },
            audioCaptureSession: NoopAudioCaptureSession(),
            audioCaptureService: audioCaptureService,
            speechAudioRecognitionRunner: speechAudioRecognitionRunner,
            checkPermissions: { _ in true },
            requestPermissions: { _ in true }
        )
    }
}

private enum AudioServiceLifecycleTestError: Error {
    case captureStartFailed
    case engineStartFailed
}

@MainActor
private final class FailingStartVoiceAudioEngine: VoiceAudioEngineManaging {
    let inputFormat = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
    private(set) var didInstallTap = false
    private(set) var didPrepare = false
    private(set) var didStop = false
    private(set) var didRemoveTap = false

    func installTap(
        bufferSize: AVAudioFrameCount,
        format: AVAudioFormat,
        handler: @escaping (AVAudioPCMBuffer) -> Void
    ) {
        didInstallTap = true
    }

    func prepare() {
        didPrepare = true
    }

    func start() throws {
        throw AudioServiceLifecycleTestError.engineStartFailed
    }

    func stop() {
        didStop = true
    }

    func removeTap() {
        didRemoveTap = true
    }
}

@MainActor
private final class RecordingSpeechAudioRecognitionRunner: SpeechAudioRecognitionRunning {
    let task = RecordingSpeechRecognitionTask()
    var isAvailable = true

    func startRecognition(
        with request: SFSpeechAudioBufferRecognitionRequest,
        resultHandler: @escaping (SpeechRecognitionTextResult?, Error?) -> Void
    ) -> any SpeechRecognitionTaskCancellable {
        task
    }
}

@MainActor
private final class RecordingSpeechRecognitionTask: SpeechRecognitionTaskCancellable {
    private(set) var didCancel = false

    func cancel() {
        didCancel = true
    }
}

@MainActor
private final class FailingStartVoiceAudioCapture: VoiceAudioCapturing {
    var audioLevel: Float = 0
    var recordingDuration: TimeInterval = 0
    var sampleRate: Double = 16_000
    var bufferHandler: ((AVAudioPCMBuffer) -> Void)?
    private(set) var cancelCalls = 0

    func start() throws {
        throw AudioServiceLifecycleTestError.captureStartFailed
    }

    func stop() async -> [Float] {
        []
    }

    func cancel() async {
        cancelCalls += 1
    }
}

@MainActor
private final class RecordingAudioCaptureSession: AudioCaptureSessionManaging {
    private(set) var activateCalls = 0
    private(set) var deactivateCalls = 0

    func activateForRecording() throws {
        activateCalls += 1
    }

    func deactivateAfterRecording() throws {
        deactivateCalls += 1
    }
}

@MainActor
private final class RecordingVoiceSampleTranscriber: VoiceSampleTranscribing {
    func transcribe(samples: [Float]) async throws -> String {
        ""
    }
}
