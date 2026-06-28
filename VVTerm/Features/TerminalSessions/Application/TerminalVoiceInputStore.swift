import Combine
import Foundation

enum TerminalVoiceInputTarget: Hashable {
    case session(UUID)
    case pane(UUID)
}

@MainActor
protocol TerminalVoiceAudioServicing: AnyObject {
    var isRecording: Bool { get }
    var transcribedText: String { get }
    var partialTranscription: String { get }
    var audioLevel: Float { get }
    var recordingDuration: TimeInterval { get }

    func startRecording() async throws
    func stopRecording() async -> String
    func cancelRecording()
}

extension AudioService: TerminalVoiceAudioServicing {}

@MainActor
final class TerminalVoiceInputStore: ObservableObject {
    static let shared = TerminalVoiceInputStore()

    @Published private(set) var activeTarget: TerminalVoiceInputTarget?
    @Published private(set) var isProcessing = false
    @Published private(set) var lastFailureMessage: String?

    private let audioService: any TerminalVoiceAudioServicing
    private var audioChangeCancellable: AnyCancellable?
    private var voiceRequests: [UUID: VoiceInputRequest] = [:]
    private var requestByKey: [VoiceInputRequestKey: UUID] = [:]

    var isRecording: Bool {
        audioService.isRecording
    }

    var transcribedText: String {
        audioService.transcribedText
    }

    var partialTranscription: String {
        audioService.partialTranscription
    }

    var audioLevel: Float {
        audioService.audioLevel
    }

    var recordingDuration: TimeInterval {
        audioService.recordingDuration
    }

    var pendingVoiceRequestIDs: Set<UUID> {
        Set(voiceRequests.keys)
    }

    convenience init() {
        self.init(audioService: AudioService())
    }

    init(audioService: any TerminalVoiceAudioServicing) {
        self.audioService = audioService
        if let observableAudioService = audioService as? AudioService {
            audioChangeCancellable = observableAudioService.objectWillChange.sink { [weak self] _ in
                self?.objectWillChange.send()
            }
        }
    }

    @discardableResult
    func requestStart(
        for target: TerminalVoiceInputTarget,
        onStarted: @escaping () -> Void = {},
        onFailed: @escaping (String) -> Void = { _ in }
    ) -> UUID {
        let key = VoiceInputRequestKey(target: target, kind: .start)
        if let existingID = requestByKey[key] {
            voiceRequests[existingID]?.onStarted.append(onStarted)
            voiceRequests[existingID]?.onFailed.append(onFailed)
            return existingID
        }

        let requestID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runStartRequest(requestID, target: target)
        }
        voiceRequests[requestID] = VoiceInputRequest(
            target: target,
            kind: .start,
            task: task,
            onStarted: [onStarted],
            onFailed: [onFailed]
        )
        requestByKey[key] = requestID
        activeTarget = target
        lastFailureMessage = nil
        return requestID
    }

    @discardableResult
    func requestStopAndSend(
        for target: TerminalVoiceInputTarget,
        onCompleted: @escaping (String) -> Void = { _ in }
    ) -> UUID {
        let key = VoiceInputRequestKey(target: target, kind: .stop)
        if let existingID = requestByKey[key] {
            voiceRequests[existingID]?.onCompleted.append(onCompleted)
            return existingID
        }

        let requestID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runStopRequest(requestID, target: target)
        }
        voiceRequests[requestID] = VoiceInputRequest(
            target: target,
            kind: .stop,
            task: task,
            onCompleted: [onCompleted]
        )
        requestByKey[key] = requestID
        isProcessing = true
        lastFailureMessage = nil
        return requestID
    }

    @discardableResult
    func requestCancel(
        for target: TerminalVoiceInputTarget,
        onCancelled: @escaping () -> Void = {}
    ) -> UUID {
        cancelPendingLifecycleRequests(for: target)
        lastFailureMessage = nil

        let key = VoiceInputRequestKey(target: target, kind: .cancel)
        if let existingID = requestByKey[key] {
            voiceRequests[existingID]?.onCancelled.append(onCancelled)
            return existingID
        }

        let requestID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            self.runCancelRequest(requestID, target: target)
        }
        voiceRequests[requestID] = VoiceInputRequest(
            target: target,
            kind: .cancel,
            task: task,
            onCancelled: [onCancelled]
        )
        requestByKey[key] = requestID
        return requestID
    }

    @discardableResult
    func requestCancelTask(
        for target: TerminalVoiceInputTarget,
        onCancelled: @escaping () -> Void = {}
    ) -> Task<Void, Never> {
        let requestID = requestCancel(for: target, onCancelled: onCancelled)
        return voiceRequests[requestID]?.task ?? Task {}
    }

    func waitForVoiceRequest(_ requestID: UUID) async {
        guard let task = voiceRequests[requestID]?.task else { return }
        await task.value
    }

    private func runStartRequest(_ requestID: UUID, target: TerminalVoiceInputTarget) async {
        do {
            try await audioService.startRecording()
            guard !Task.isCancelled, activeTarget == target else {
                audioService.cancelRecording()
                _ = finishRequest(requestID)
                objectWillChange.send()
                return
            }
            guard let request = finishRequest(requestID) else { return }
            request.onStarted.forEach { $0() }
            objectWillChange.send()
        } catch is CancellationError {
            activeTarget = nil
            isProcessing = false
            _ = finishRequest(requestID)
            objectWillChange.send()
        } catch {
            let message = failureMessage(for: error)
            activeTarget = nil
            isProcessing = false
            lastFailureMessage = message
            guard let request = finishRequest(requestID) else { return }
            request.onFailed.forEach { $0(message) }
            objectWillChange.send()
        }
    }

    private func runStopRequest(_ requestID: UUID, target: TerminalVoiceInputTarget) async {
        let finalText = await audioService.stopRecording()
        guard !Task.isCancelled, activeTarget == target else {
            isProcessing = false
            _ = finishRequest(requestID)
            objectWillChange.send()
            return
        }
        let output = finalText.isEmpty ? audioService.partialTranscription : finalText
        if activeTarget == target {
            activeTarget = nil
        }
        isProcessing = false
        guard let request = finishRequest(requestID) else { return }
        request.onCompleted.forEach { $0(output) }
        objectWillChange.send()
    }

    private func runCancelRequest(_ requestID: UUID, target: TerminalVoiceInputTarget) {
        audioService.cancelRecording()
        if activeTarget == target {
            activeTarget = nil
        }
        isProcessing = false
        guard let request = finishRequest(requestID) else { return }
        request.onCancelled.forEach { $0() }
        objectWillChange.send()
    }

    private func finishRequest(_ requestID: UUID) -> VoiceInputRequest? {
        guard let request = voiceRequests.removeValue(forKey: requestID) else {
            return nil
        }
        requestByKey[VoiceInputRequestKey(target: request.target, kind: request.kind)] = nil
        return request
    }

    private func cancelPendingLifecycleRequests(for target: TerminalVoiceInputTarget) {
        for request in voiceRequests.values where request.target == target && request.kind != .cancel {
            request.task.cancel()
        }
    }

    private func failureMessage(for error: Error) -> String {
        if let recordingError = error as? AudioService.RecordingError {
            return recordingError.localizedDescription
                + "\n\n"
                + String(localized: "Enable Microphone and Speech Recognition in System Settings.")
        }
        return error.localizedDescription
    }
}

private struct VoiceInputRequestKey: Hashable {
    let target: TerminalVoiceInputTarget
    let kind: VoiceInputRequestKind
}

private enum VoiceInputRequestKind: Hashable {
    case start
    case stop
    case cancel
}

private struct VoiceInputRequest {
    let target: TerminalVoiceInputTarget
    let kind: VoiceInputRequestKind
    let task: Task<Void, Never>
    var onStarted: [() -> Void] = []
    var onFailed: [(String) -> Void] = []
    var onCompleted: [(String) -> Void] = []
    var onCancelled: [() -> Void] = []
}
