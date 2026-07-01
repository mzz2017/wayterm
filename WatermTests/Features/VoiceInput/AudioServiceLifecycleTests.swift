import AVFoundation
import Foundation
import Speech
import Testing
@testable import Waterm

// Test Context:
// These tests protect VoiceInput start-failure and start-cancellation rollback.
// AudioService may await permission checks before touching the microphone,
// start Apple Speech before the microphone capture service starts, and
// AudioCaptureService may activate the platform audio session before
// AVAudioEngine starts. Cancellation or failure in these half-started paths must
// release the owned runtime resources before returning. Fakes avoid real
// microphone, Speech, and model access while preserving the start/cancel
// ordering being tested.
@MainActor
struct AudioServiceLifecycleTests {
    @Test
    func canceledPermissionCheckDoesNotStartCaptureAfterPermissionResumes() async throws {
        let permissionGate = PermissionGate()
        let capture = RecordingStartVoiceAudioCapture()
        let service = AudioService(
            dependencies: makeDependencies(
                audioCaptureService: capture,
                speechAudioRecognitionRunner: RecordingSpeechAudioRecognitionRunner(),
                checkPermissions: { _ in await permissionGate.waitForPermissionResult() }
            )
        )

        // Given voice start is waiting for permission state before opening the
        // microphone runtime.
        let startTask = Task {
            try await service.startRecording()
        }
        await permissionGate.waitUntilPermissionRequested()

        // When lifecycle cancellation wins before the permission await resumes.
        startTask.cancel()
        await service.cancelRecording()
        await permissionGate.resolvePermission(true)

        do {
            try await startTask.value
        } catch is CancellationError {
            // Expected once AudioService observes the canceled start task.
        }

        // Then a canceled start must not activate capture after permission is
        // eventually granted.
        #expect(capture.startCalls == 0, "Canceled voice start must not open microphone capture after permission resumes.")
        #expect(!service.isRecording, "Canceled voice start must not publish an active recording state.")
    }

    @Test
    func canceledResetCancelDoesNotStartCaptureAfterCancelResumes() async throws {
        let capture = BlockingCancelVoiceAudioCapture()
        let service = AudioService(
            dependencies: makeDependencies(
                audioCaptureService: capture,
                speechAudioRecognitionRunner: RecordingSpeechAudioRecognitionRunner()
            )
        )

        // Given voice start has passed permission checks and is waiting for
        // reset cancellation before reopening the microphone runtime.
        let startTask = Task {
            try await service.startRecording()
        }
        await capture.waitUntilCancelStarted()

        // When lifecycle cancellation wins while reset cancellation is still
        // suspended.
        startTask.cancel()
        capture.releaseCancel()

        do {
            try await startTask.value
        } catch is CancellationError {
            // Expected once AudioService observes the canceled start task.
        }

        // Then the canceled start must not continue into Apple Speech or
        // microphone capture after reset cancellation resumes.
        #expect(capture.startCalls == 0, "Canceled voice start must not open microphone capture after reset cancellation resumes.")
        #expect(!service.isRecording, "Canceled voice start must not publish an active recording state.")
    }

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
    func cancelRecordingCancelsInFlightMLXTranscription() async throws {
        let transcriber = BlockingVoiceSampleTranscriber()
        let capture = RecordingStopVoiceAudioCapture(samples: [0.1, 0.2])
        let service = AudioService(
            dependencies: makeDependencies(
                provider: .mlxWhisper,
                whisperProvider: transcriber,
                isWhisperSupported: true,
                isModelAvailable: true,
                audioCaptureService: capture,
                speechAudioRecognitionRunner: RecordingSpeechAudioRecognitionRunner()
            )
        )

        // Given MLX recording is active and stop has entered long-running
        // transcription after microphone capture is closed.
        try await service.startRecording()
        let stopTask = Task { @MainActor in
            await service.stopRecording()
        }
        await transcriber.waitForTranscribeCall()

        // When terminal lifecycle cancellation asks AudioService to cancel the
        // voice runtime while transcription is still running.
        await service.cancelRecording()
        try await Task.sleep(for: .milliseconds(20))

        // Then the in-flight MLX transcription task must be cancelled instead
        // of continuing after the terminal has closed.
        #expect(
            transcriber.didCancel,
            "Canceling recording should cancel the in-flight MLX transcription task."
        )
        transcriber.release("late command")
        let result = await stopTask.value
        #expect(result.isEmpty, "Canceled MLX transcription should not return late command text.")
        #expect(service.transcribedText.isEmpty, "Canceled MLX transcription should not publish late text.")
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
        provider: TranscriptionProvider = .system,
        whisperProvider: (any VoiceSampleTranscribing)? = nil,
        parakeetProvider: (any VoiceSampleTranscribing)? = nil,
        isWhisperSupported: Bool = false,
        isParakeetSupported: Bool = false,
        isModelAvailable: Bool = false,
        audioCaptureService: any VoiceAudioCapturing,
        speechAudioRecognitionRunner: any SpeechAudioRecognitionRunning,
        checkPermissions: (@MainActor (Bool) async -> Bool)? = nil,
        requestPermissions: (@MainActor (Bool) async -> Bool)? = nil
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
            whisperProvider: whisperProvider ?? RecordingVoiceSampleTranscriber(),
            parakeetProvider: parakeetProvider ?? RecordingVoiceSampleTranscriber(),
            isWhisperSupported: { isWhisperSupported },
            isParakeetSupported: { isParakeetSupported },
            isModelAvailable: { _, _ in isModelAvailable },
            audioCaptureSession: NoopAudioCaptureSession(),
            audioCaptureService: audioCaptureService,
            speechAudioRecognitionRunner: speechAudioRecognitionRunner,
            checkPermissions: checkPermissions ?? { _ in true },
            requestPermissions: requestPermissions ?? { _ in true }
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
private final class RecordingStartVoiceAudioCapture: VoiceAudioCapturing {
    var audioLevel: Float = 0
    var recordingDuration: TimeInterval = 0
    var sampleRate: Double = 16_000
    var bufferHandler: ((AVAudioPCMBuffer) -> Void)?
    private(set) var startCalls = 0
    private(set) var cancelCalls = 0

    func start() throws {
        startCalls += 1
    }

    func stop() async -> [Float] {
        []
    }

    func cancel() async {
        cancelCalls += 1
    }
}

@MainActor
private final class RecordingStopVoiceAudioCapture: VoiceAudioCapturing {
    var audioLevel: Float = 0
    var recordingDuration: TimeInterval = 0
    var sampleRate: Double = 16_000
    var bufferHandler: ((AVAudioPCMBuffer) -> Void)?
    private let samples: [Float]
    private(set) var startCalls = 0
    private(set) var stopCalls = 0
    private(set) var cancelCalls = 0

    init(samples: [Float]) {
        self.samples = samples
    }

    func start() throws {
        startCalls += 1
    }

    func stop() async -> [Float] {
        stopCalls += 1
        return samples
    }

    func cancel() async {
        cancelCalls += 1
    }
}

@MainActor
private final class BlockingCancelVoiceAudioCapture: VoiceAudioCapturing {
    var audioLevel: Float = 0
    var recordingDuration: TimeInterval = 0
    var sampleRate: Double = 16_000
    var bufferHandler: ((AVAudioPCMBuffer) -> Void)?
    private(set) var startCalls = 0
    private var cancelStartedContinuations: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func start() throws {
        startCalls += 1
    }

    func stop() async -> [Float] {
        []
    }

    func cancel() async {
        let startedContinuations = cancelStartedContinuations
        cancelStartedContinuations.removeAll()
        startedContinuations.forEach { $0.resume() }

        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilCancelStarted() async {
        if releaseContinuation != nil { return }
        await withCheckedContinuation { continuation in
            cancelStartedContinuations.append(continuation)
        }
    }

    func releaseCancel() {
        releaseContinuation?.resume()
        releaseContinuation = nil
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

@MainActor
private final class BlockingVoiceSampleTranscriber: VoiceSampleTranscribing {
    private var transcribeCallContinuations: [CheckedContinuation<Void, Never>] = []
    private var continuation: CheckedContinuation<String, Error>?
    private(set) var transcribeCallCount = 0
    private(set) var didCancel = false

    func transcribe(samples: [Float]) async throws -> String {
        transcribeCallCount += 1
        let callContinuations = transcribeCallContinuations
        transcribeCallContinuations.removeAll()
        callContinuations.forEach { $0.resume() }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
            }
        } onCancel: {
            Task { @MainActor in
                self.didCancel = true
                self.continuation?.resume(throwing: CancellationError())
                self.continuation = nil
            }
        }
    }

    func waitForTranscribeCall() async {
        guard transcribeCallCount == 0 else { return }
        await withCheckedContinuation { continuation in
            transcribeCallContinuations.append(continuation)
        }
    }

    func release(_ text: String) {
        continuation?.resume(returning: text)
        continuation = nil
    }
}

private actor PermissionGate {
    private var permissionContinuation: CheckedContinuation<Bool, Never>?
    private var didRequestPermission = false
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []

    func waitForPermissionResult() async -> Bool {
        didRequestPermission = true
        let waiters = requestWaiters
        requestWaiters.removeAll()
        waiters.forEach { $0.resume() }

        return await withCheckedContinuation { continuation in
            permissionContinuation = continuation
        }
    }

    func waitUntilPermissionRequested() async {
        guard !didRequestPermission else { return }
        await withCheckedContinuation { continuation in
            requestWaiters.append(continuation)
        }
    }

    func resolvePermission(_ value: Bool) {
        permissionContinuation?.resume(returning: value)
        permissionContinuation = nil
    }
}
