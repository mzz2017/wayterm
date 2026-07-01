import Foundation
import Combine
import AVFoundation

@MainActor
protocol AudioCaptureSessionManaging {
    func activateForRecording() throws
    func deactivateAfterRecording() throws
}

@MainActor
protocol VoiceAudioCapturing: AnyObject {
    var audioLevel: Float { get }
    var recordingDuration: TimeInterval { get }
    var sampleRate: Double { get }
    var bufferHandler: ((AVAudioPCMBuffer) -> Void)? { get set }

    func start() throws
    func stop() async -> [Float]
    func cancel() async
}

@MainActor
protocol VoiceAudioEngineManaging: AnyObject {
    var inputFormat: AVAudioFormat { get }

    func installTap(
        bufferSize: AVAudioFrameCount,
        format: AVAudioFormat,
        handler: @escaping (AVAudioPCMBuffer) -> Void
    )
    func prepare()
    func start() throws
    func stop()
    func removeTap()
}

@MainActor
private final class LiveVoiceAudioEngine: VoiceAudioEngineManaging {
    private let engine = AVAudioEngine()

    var inputFormat: AVAudioFormat {
        engine.inputNode.outputFormat(forBus: 0)
    }

    func installTap(
        bufferSize: AVAudioFrameCount,
        format: AVAudioFormat,
        handler: @escaping (AVAudioPCMBuffer) -> Void
    ) {
        engine.inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: format) { buffer, _ in
            handler(buffer)
        }
    }

    func prepare() {
        engine.prepare()
    }

    func start() throws {
        try engine.start()
    }

    func stop() {
        engine.stop()
    }

    func removeTap() {
        engine.inputNode.removeTap(onBus: 0)
    }
}

@MainActor
struct NoopAudioCaptureSession: AudioCaptureSessionManaging {
    func activateForRecording() throws {}
    func deactivateAfterRecording() throws {}
}

@MainActor
final class AudioCaptureService: ObservableObject, VoiceAudioCapturing {
    @Published var audioLevel: Float = 0.0
    @Published var recordingDuration: TimeInterval = 0

    var bufferHandler: ((AVAudioPCMBuffer) -> Void)?
    private(set) var lastSessionDeactivationError: Error?

    private let targetSampleRate: Double = 16_000
    private let audioSession: any AudioCaptureSessionManaging
    nonisolated private let bufferUpdateTasks = AudioBufferUpdateTaskRegistry()
    private var audioEngine: (any VoiceAudioEngineManaging)?
    private var converter: AVAudioConverter?
    private var recordedSamples: [Float] = []
    private var isRecording = false
    private let makeEngine: @MainActor () -> any VoiceAudioEngineManaging

    init(
        audioSession: (any AudioCaptureSessionManaging)? = nil,
        makeEngine: @escaping @MainActor () -> any VoiceAudioEngineManaging = { LiveVoiceAudioEngine() }
    ) {
        self.audioSession = audioSession ?? NoopAudioCaptureSession()
        self.makeEngine = makeEngine
    }

    var sampleRate: Double { targetSampleRate }

    func start() throws {
        if isRecording { return }

        recordedSamples.removeAll(keepingCapacity: true)
        audioLevel = 0
        recordingDuration = 0
        lastSessionDeactivationError = nil

        var didActivateSession = false
        var didInstallTap = false
        var engine: (any VoiceAudioEngineManaging)?

        do {
            try audioSession.activateForRecording()
            didActivateSession = true

            let captureEngine = makeEngine()
            engine = captureEngine
            let inputFormat = captureEngine.inputFormat
            let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: targetSampleRate, channels: 1, interleaved: false)!
            let converter = AVAudioConverter(from: inputFormat, to: targetFormat)

            guard let converter else {
                throw RecordingError.converterUnavailable
            }

            self.audioEngine = captureEngine
            self.converter = converter

            captureEngine.installTap(bufferSize: 1024, format: inputFormat) { [weak self] buffer in
                self?.handleBuffer(buffer, inputFormat: inputFormat, targetFormat: targetFormat)
            }
            didInstallTap = true

            captureEngine.prepare()
            try captureEngine.start()
            isRecording = true
        } catch {
            if didInstallTap {
                engine?.removeTap()
            }
            engine?.stop()
            audioEngine = nil
            converter = nil
            audioLevel = 0
            recordingDuration = 0
            recordedSamples.removeAll(keepingCapacity: false)

            if didActivateSession {
                do {
                    try audioSession.deactivateAfterRecording()
                } catch {
                    lastSessionDeactivationError = error
                }
            }

            throw error
        }
    }

    func stop() async -> [Float] {
        guard isRecording else {
            await waitForBufferUpdateTasks()
            return []
        }
        isRecording = false

        if let engine = audioEngine {
            engine.removeTap()
            engine.stop()
        }

        await waitForBufferUpdateTasks()

        // Release the session so system services (e.g. keyboard dictation) regain the mic.
        do {
            try audioSession.deactivateAfterRecording()
        } catch {
            lastSessionDeactivationError = error
        }

        audioEngine = nil
        converter = nil
        audioLevel = 0
        recordingDuration = 0
        let samples = recordedSamples
        recordedSamples.removeAll(keepingCapacity: false)
        return samples
    }

    func cancel() async {
        _ = await stop()
        recordedSamples.removeAll(keepingCapacity: false)
        audioLevel = 0
        recordingDuration = 0
    }

    private func handleBuffer(_ buffer: AVAudioPCMBuffer, inputFormat: AVAudioFormat, targetFormat: AVAudioFormat) {
        guard let converter else { return }

        let ratio = targetSampleRate / inputFormat.sampleRate
        let outputFrameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
        guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCapacity) else {
            return
        }

        var error: NSError?
        let inputProvider = AudioConverterInputBufferProvider(buffer: buffer)
        converter.convert(to: convertedBuffer, error: &error, withInputFrom: inputProvider.makeInputBlock())

        if error != nil {
            bufferUpdateTasks.track { [weak self] in
                self?.audioLevel = 0
            }
            return
        }

        guard let channelData = convertedBuffer.floatChannelData else { return }
        let frameLength = Int(convertedBuffer.frameLength)
        let samples = Array(UnsafeBufferPointer(start: channelData[0], count: frameLength))

        bufferUpdateTasks.track { [weak self] in
            guard let self else { return }
            self.updateMetrics(with: samples)
            self.bufferHandler?(convertedBuffer)
        }
    }

    private func waitForBufferUpdateTasks() async {
        await bufferUpdateTasks.waitForAll()
    }

    private func updateMetrics(with samples: [Float]) {
        guard !samples.isEmpty else { return }

        let sumSquares = samples.reduce(0.0) { $0 + ($1 * $1) }
        let rms = sqrt(sumSquares / Float(samples.count))
        audioLevel = min(max(rms * 3, 0.05), 1.0)

        recordedSamples.append(contentsOf: samples)
        recordingDuration = Double(recordedSamples.count) / targetSampleRate
    }

    enum RecordingError: LocalizedError {
        case converterUnavailable

        var errorDescription: String? {
            switch self {
            case .converterUnavailable:
                return "Failed to configure audio converter."
            }
        }
    }
}
