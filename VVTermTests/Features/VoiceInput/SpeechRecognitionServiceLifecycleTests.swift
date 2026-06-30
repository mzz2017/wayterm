import Foundation
import Speech
import Testing
@testable import VVTerm

// Test Context:
// These tests protect Apple Speech fallback transcription cleanup. URL-based
// speech recognition is a system callback API; cancellation must resume the
// awaiting transcription continuation and remove the temporary audio file even
// if Speech never calls its result handler after cancel.

@MainActor
struct SpeechRecognitionServiceLifecycleTests {
    @Test
    func cancelRecognitionIgnoresLateLiveAudioCallbacks() async throws {
        let runner = ScriptedSpeechAudioRecognitionRunner()
        let service = SpeechRecognitionService(
            settings: TranscriptionSettingsReader {
                TranscriptionSettingsSnapshot(
                    provider: .system,
                    whisperModelId: "",
                    parakeetModelId: "",
                    languageCode: "en"
                )
            },
            audioRecognitionRunner: runner
        )

        // Given live Apple Speech recognition starts, publishes a partial, and
        // is then canceled before the system finishes delivering callbacks.
        try await service.startRecognition()
        let firstRequest = try #require(runner.requests.first)
        await runner.emitPartial("old command", for: firstRequest)
        #expect(service.partialTranscription == "old command")

        service.cancelRecognition()
        #expect(service.partialTranscription.isEmpty)

        // When a new recognition lifecycle starts and the old system callback
        // arrives late.
        try await service.startRecognition()
        await runner.emitPartial("stale command", for: firstRequest)

        // Then the canceled lifecycle cannot republish stale command text into
        // the active recording state.
        #expect(
            service.partialTranscription.isEmpty,
            "Late callbacks from a canceled live Speech request must not publish stale partial transcription."
        )
    }

    @Test
    func cancelRecognitionCompletesPendingURLTranscriptionAndRemovesTemporaryFile() async throws {
        let runner = HangingSpeechURLRecognitionRunner()
        let service = SpeechRecognitionService(
            settings: TranscriptionSettingsReader {
                TranscriptionSettingsSnapshot(
                    provider: .system,
                    whisperModelId: "",
                    parakeetModelId: "",
                    languageCode: "en"
                )
            },
            urlRecognitionRunner: runner
        )

        // Given Apple Speech URL transcription has started and the system
        // recognizer never calls its completion handler.
        let transcriptionTask = Task { @MainActor in
            try await service.transcribe(samples: Array(repeating: 0.1, count: 160), sampleRate: 16_000)
        }
        await runner.waitUntilStarted()
        let temporaryURL = try #require(runner.requestURL)
        #expect(
            FileManager.default.fileExists(atPath: temporaryURL.path),
            "The fallback transcription should create a temporary CAF file before starting URL recognition."
        )

        // When lifecycle cleanup cancels recognition.
        service.cancelRecognition()

        // Then the suspended transcription resumes as cancellation and the
        // system task plus temporary file are cleaned up.
        do {
            _ = try await transcriptionTask.value
            Issue.record("Expected canceled URL transcription to throw CancellationError")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }

        #expect(runner.task.didCancel, "cancelRecognition should cancel the in-flight Speech task.")
        #expect(
            !FileManager.default.fileExists(atPath: temporaryURL.path),
            "cancelRecognition should remove the temporary CAF file even when Speech never calls back."
        )
    }
}

@MainActor
private final class ScriptedSpeechAudioRecognitionRunner: SpeechAudioRecognitionRunning {
    let task = FakeSpeechRecognitionTask()
    private(set) var requests: [SFSpeechAudioBufferRecognitionRequest] = []
    private var handlers: [ObjectIdentifier: (SpeechRecognitionTextResult?, Error?) -> Void] = [:]

    var isAvailable: Bool { true }

    func startRecognition(
        with request: SFSpeechAudioBufferRecognitionRequest,
        resultHandler: @escaping (SpeechRecognitionTextResult?, Error?) -> Void
    ) -> any SpeechRecognitionTaskCancellable {
        requests.append(request)
        handlers[ObjectIdentifier(request)] = resultHandler
        return task
    }

    func emitPartial(_ text: String, for request: SFSpeechAudioBufferRecognitionRequest) async {
        handlers[ObjectIdentifier(request)]?(SpeechRecognitionTextResult(text: text, isFinal: false), nil)
        await Task.yield()
    }
}

@MainActor
private final class HangingSpeechURLRecognitionRunner: SpeechURLRecognitionRunning {
    let task = FakeSpeechRecognitionTask()
    private(set) var requestURL: URL?
    private var started = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var isAvailable: Bool { true }

    func startRecognition(
        with request: SFSpeechURLRecognitionRequest,
        resultHandler: @escaping (SFSpeechRecognitionResult?, Error?) -> Void
    ) -> any SpeechRecognitionTaskCancellable {
        requestURL = request.url
        started = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
        return task
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

private final class FakeSpeechRecognitionTask: SpeechRecognitionTaskCancellable {
    private(set) var didCancel = false

    func cancel() {
        didCancel = true
    }
}
