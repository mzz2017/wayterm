import Foundation
import Testing
@testable import VVTerm

// Test Context:
// These tests protect terminal voice input lifecycle ownership. Terminal UI may
// present recording controls and send start/stop/cancel intent, while a
// TerminalSessions application-layer store owns AudioService and the async
// microphone/transcription request tasks. Fakes model ordering, permission
// failure, fallback text, and cancellation only; they do not use the real
// microphone, Speech, MLX, or permissions. Update these tests only when voice
// lifecycle ownership intentionally moves to another non-UI application owner.

@Suite(.serialized)
@MainActor
struct TerminalVoiceInputStoreTests {
    @Test
    func startRequestTracksTaskUntilAudioStartupCompletes() async {
        let audio = FakeTerminalVoiceAudioService()
        let store = TerminalVoiceInputStore(audioService: audio)
        let target = TerminalVoiceInputTarget.session(UUID())
        var didStart = false
        var failureMessage: String?

        // Given terminal UI sends start-recording intent and audio startup is
        // still blocked in the application-layer owner.
        let requestID = store.requestStart(
            for: target,
            onStarted: { didStart = true },
            onFailed: { failureMessage = $0 }
        )
        await audio.waitForStartCallCount(1)

        // Then the request remains tracked and no UI callback fires early.
        #expect(store.pendingVoiceRequestIDs == [requestID])
        #expect(store.activeTarget == target)
        #expect(didStart == false)
        #expect(failureMessage == nil)

        await audio.releaseStart()
        await store.waitForVoiceRequest(requestID)

        #expect(didStart == true)
        #expect(failureMessage == nil)
        #expect(store.pendingVoiceRequestIDs.isEmpty)
        #expect(store.isRecording == true)
    }

    @Test
    func failedStartRequestReportsPermissionMessageWithoutRecording() async {
        let audio = FakeTerminalVoiceAudioService()
        audio.startError = AudioService.RecordingError.permissionDenied
        let store = TerminalVoiceInputStore(audioService: audio)
        let target = TerminalVoiceInputTarget.session(UUID())
        var didStart = false
        var failureMessage: String?

        // Given audio startup fails with a user-facing recording error.
        let requestID = store.requestStart(
            for: target,
            onStarted: { didStart = true },
            onFailed: { failureMessage = $0 }
        )
        await audio.waitForStartCallCount(1)
        await audio.releaseStart()

        // When the application-layer request completes.
        await store.waitForVoiceRequest(requestID)

        // Then cancellation/error state is owned by the store and recording is
        // not presented as active.
        #expect(didStart == false)
        #expect(
            failureMessage?.contains("Microphone") == true,
            "Permission failures should preserve the actionable AudioService message."
        )
        #expect(store.isRecording == false)
        #expect(store.activeTarget == nil)
        #expect(store.pendingVoiceRequestIDs.isEmpty)
    }

    @Test
    func stopRequestTracksTaskAndUsesPartialTranscriptionFallback() async {
        let audio = FakeTerminalVoiceAudioService()
        audio.partialTranscription = "uptime"
        audio.stopText = ""
        let store = TerminalVoiceInputStore(audioService: audio)
        let target = TerminalVoiceInputTarget.pane(UUID())
        var output: String?

        let startID = store.requestStart(for: target)
        await audio.waitForStartCallCount(1)
        await audio.releaseStart()
        await store.waitForVoiceRequest(startID)

        // Given recording is active and stop/transcription work is blocked.
        let stopID = store.requestStopAndSend(
            for: target,
            onCompleted: { output = $0 }
        )
        await audio.waitForStopCallCount(1)

        // Then processing remains application-owned until transcription
        // completes.
        #expect(store.pendingVoiceRequestIDs == [stopID])
        #expect(store.isProcessing == true)
        #expect(output == nil)

        await audio.releaseStop()
        await store.waitForVoiceRequest(stopID)

        #expect(output == "uptime")
        #expect(store.pendingVoiceRequestIDs.isEmpty)
        #expect(store.isProcessing == false)
        #expect(store.activeTarget == nil)
    }

    @Test
    func cancelRequestClearsRecordingWithoutSurfacingFailure() async {
        let audio = FakeTerminalVoiceAudioService()
        let store = TerminalVoiceInputStore(audioService: audio)
        let target = TerminalVoiceInputTarget.session(UUID())
        var didCancel = false

        let startID = store.requestStart(for: target)
        await audio.waitForStartCallCount(1)
        await audio.releaseStart()
        await store.waitForVoiceRequest(startID)

        // When terminal UI sends cancel intent.
        let cancelID = store.requestCancel(
            for: target,
            onCancelled: { didCancel = true }
        )
        await store.waitForVoiceRequest(cancelID)

        // Then cancel is lifecycle completion, not a user-facing recording
        // failure.
        #expect(didCancel == true)
        #expect(audio.cancelCallCount == 1)
        #expect(store.activeTarget == nil)
        #expect(store.isRecording == false)
        #expect(store.isProcessing == false)
        #expect(store.lastFailureMessage == nil)
    }

    @Test
    func cancelRequestPreventsLateStartCompletionFromReopeningRecording() async {
        let audio = FakeTerminalVoiceAudioService()
        let store = TerminalVoiceInputStore(audioService: audio)
        let target = TerminalVoiceInputTarget.session(UUID())
        var didStart = false
        var didCancel = false

        // Given audio startup is still blocked after UI sends start intent.
        let startID = store.requestStart(
            for: target,
            onStarted: { didStart = true }
        )
        await audio.waitForStartCallCount(1)

        // When UI cancels before startup finishes.
        let cancelID = store.requestCancel(
            for: target,
            onCancelled: { didCancel = true }
        )
        await store.waitForVoiceRequest(cancelID)

        // Then the late start completion must not reopen recording or fire the
        // stale started callback.
        await audio.releaseStart()
        await store.waitForVoiceRequest(startID)

        #expect(didCancel == true)
        #expect(didStart == false)
        #expect(store.activeTarget == nil)
        #expect(store.isRecording == false)
    }

    @Test
    func cancelTaskWaitsForCanceledStopRequestBeforeCompletion() async throws {
        let audio = FakeTerminalVoiceAudioService()
        audio.stopText = "shutdown now"
        let store = TerminalVoiceInputStore(audioService: audio)
        let target = TerminalVoiceInputTarget.session(UUID())
        var didCancel = false
        let waitProbe = TerminalVoiceInputWaitProbe()

        let startID = store.requestStart(for: target)
        await audio.waitForStartCallCount(1)
        await audio.releaseStart()
        await store.waitForVoiceRequest(startID)

        // Given transcription stop work is in flight for a target that is closing.
        let stopID = store.requestStopAndSend(for: target)
        await audio.waitForStopCallCount(1)

        // When close asks for a cancellable voice cleanup task.
        let cancelTask = store.requestCancelTask(
            for: target,
            onCancelled: { didCancel = true }
        )
        let waitTask = Task { @MainActor in
            await cancelTask.value
            await waitProbe.markFinished()
        }
        try await Task.sleep(for: .milliseconds(20))

        // Then cancel remains awaitable until the canceled transcription task exits.
        #expect(
            await !waitProbe.didFinish(),
            "Voice cancel cleanup should wait for a canceled stop/transcription task to exit before close returns."
        )
        #expect(store.pendingVoiceRequestIDs.contains(stopID))

        await audio.releaseStop()
        await waitTask.value
        await store.waitForVoiceRequest(stopID)

        #expect(didCancel == true)
        #expect(await waitProbe.didFinish())
        #expect(store.pendingVoiceRequestIDs.isEmpty)
        #expect(store.activeTarget == nil)
        #expect(store.isProcessing == false)
        #expect(store.isRecording == false)
    }
}

@MainActor
private final class FakeTerminalVoiceAudioService: TerminalVoiceAudioServicing {
    var isRecording = false
    var transcribedText = ""
    var partialTranscription = ""
    var audioLevel: Float = 0
    var recordingDuration: TimeInterval = 0
    var startError: Error?
    var stopText = ""
    private(set) var cancelCallCount = 0
    private let startGate = TerminalVoiceInputGate()
    private let stopGate = TerminalVoiceInputGate()

    func startRecording() async throws {
        await startGate.recordCall()
        await startGate.waitUntilOpen()
        if let startError {
            throw startError
        }
        isRecording = true
    }

    func stopRecording() async -> String {
        await stopGate.recordCall()
        await stopGate.waitUntilOpen()
        isRecording = false
        return stopText
    }

    func cancelRecording() {
        cancelCallCount += 1
        isRecording = false
        transcribedText = ""
        partialTranscription = ""
    }

    func waitForStartCallCount(_ expected: Int) async {
        await startGate.waitForCallCount(expected)
    }

    func waitForStopCallCount(_ expected: Int) async {
        await stopGate.waitForCallCount(expected)
    }

    func releaseStart() async {
        await startGate.open()
    }

    func releaseStop() async {
        await stopGate.open()
    }
}

private actor TerminalVoiceInputGate {
    private var isOpen = false
    private var callCount = 0
    private var callContinuations: [CheckedContinuation<Void, Never>] = []
    private var openContinuations: [CheckedContinuation<Void, Never>] = []

    func recordCall() {
        callCount += 1
        let ready = callContinuations
        callContinuations.removeAll()
        for continuation in ready {
            continuation.resume()
        }
    }

    func waitForCallCount(_ expected: Int) async {
        if callCount >= expected { return }
        await withCheckedContinuation { continuation in
            callContinuations.append(continuation)
        }
        if callCount < expected {
            await waitForCallCount(expected)
        }
    }

    func open() {
        isOpen = true
        let ready = openContinuations
        openContinuations.removeAll()
        for continuation in ready {
            continuation.resume()
        }
    }

    func waitUntilOpen() async {
        if isOpen { return }
        await withCheckedContinuation { continuation in
            openContinuations.append(continuation)
        }
    }
}

private actor TerminalVoiceInputWaitProbe {
    private var finished = false

    func markFinished() {
        finished = true
    }

    func didFinish() -> Bool {
        finished
    }
}
