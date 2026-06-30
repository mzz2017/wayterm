import Foundation
import Combine
import Speech
import AVFoundation

@MainActor
protocol SpeechRecognitionTaskCancellable: AnyObject {
    func cancel()
}

extension SFSpeechRecognitionTask: SpeechRecognitionTaskCancellable {}

@MainActor
protocol SpeechURLRecognitionRunning: AnyObject {
    var isAvailable: Bool { get }

    func startRecognition(
        with request: SFSpeechURLRecognitionRequest,
        resultHandler: @escaping (SFSpeechRecognitionResult?, Error?) -> Void
    ) -> any SpeechRecognitionTaskCancellable
}

@MainActor
private final class LiveSpeechURLRecognitionRunner: SpeechURLRecognitionRunning {
    private let recognizer: SFSpeechRecognizer

    init(recognizer: SFSpeechRecognizer) {
        self.recognizer = recognizer
    }

    var isAvailable: Bool {
        recognizer.isAvailable
    }

    func startRecognition(
        with request: SFSpeechURLRecognitionRequest,
        resultHandler: @escaping (SFSpeechRecognitionResult?, Error?) -> Void
    ) -> any SpeechRecognitionTaskCancellable {
        recognizer.recognitionTask(with: request, resultHandler: resultHandler)
    }
}

@MainActor
class SpeechRecognitionService: ObservableObject {
    @Published var transcribedText = ""
    @Published var partialTranscription = ""

    private var speechRecognizer: SFSpeechRecognizer?
    private var recognizerLanguageCode: String?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: (any SpeechRecognitionTaskCancellable)?
    private var urlRecognitionContinuation: URLRecognitionContinuation?
    private let settings: TranscriptionSettingsReader
    private let injectedURLRecognitionRunner: (any SpeechURLRecognitionRunning)?

    var isAvailable: Bool {
        resolvedURLRecognitionRunner()?.isAvailable ?? false
    }

    init(
        settings: TranscriptionSettingsReader,
        urlRecognitionRunner: (any SpeechURLRecognitionRunning)? = nil
    ) {
        self.settings = settings
        self.injectedURLRecognitionRunner = urlRecognitionRunner
    }

    // MARK: - Recognizer Resolution

    private static let preferredLocaleIdentifiers: [String: String] = [
        "en": "en-US",
        "es": "es-ES",
        "fr": "fr-FR",
        "de": "de-DE",
        "ja": "ja-JP",
        "zh": "zh-CN",
        "ko": "ko-KR",
        "pt": "pt-BR",
        "ru": "ru-RU"
    ]

    private func resolvedRecognizer() -> SFSpeechRecognizer? {
        let languageCode = settings.current().languageCode
        if let speechRecognizer, recognizerLanguageCode == languageCode {
            return speechRecognizer
        }
        let recognizer = Self.makeRecognizer(languageCode: languageCode)
        speechRecognizer = recognizer
        recognizerLanguageCode = languageCode
        return recognizer
    }

    private static func makeRecognizer(languageCode: String) -> SFSpeechRecognizer? {
        for locale in candidateLocales(languageCode: languageCode) {
            if let recognizer = SFSpeechRecognizer(locale: locale) {
                return recognizer
            }
        }
        return SFSpeechRecognizer()
    }

    private func resolvedURLRecognitionRunner() -> (any SpeechURLRecognitionRunning)? {
        if let injectedURLRecognitionRunner {
            return injectedURLRecognitionRunner
        }
        guard let recognizer = resolvedRecognizer() else { return nil }
        return LiveSpeechURLRecognitionRunner(recognizer: recognizer)
    }

    private static func candidateLocales(languageCode: String) -> [Locale] {
        guard languageCode != TranscriptionSettingsDefaults.autoLanguageCode else {
            return [Locale.current]
        }

        var identifiers: [String] = []
        if let preferred = preferredLocaleIdentifiers[languageCode] {
            identifiers.append(preferred)
        }
        let supportedMatches = SFSpeechRecognizer.supportedLocales()
            .filter { $0.language.languageCode?.identifier == languageCode }
            .map(\.identifier)
            .sorted()
        identifiers.append(contentsOf: supportedMatches)
        identifiers.append(languageCode)

        var seen = Set<String>()
        return identifiers.compactMap { identifier in
            guard seen.insert(identifier).inserted else { return nil }
            return Locale(identifier: identifier)
        }
    }

    // MARK: - Recognition Control

    func startRecognition() async throws {
        guard let speechRecognizer = resolvedRecognizer(), speechRecognizer.isAvailable else {
            throw SpeechRecognitionError.recognitionUnavailable
        }

        recognitionRequest?.endAudio()
        recognitionRequest = nil

        recognitionTask?.cancel()
        recognitionTask = nil

        let recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        self.recognitionRequest = recognitionRequest
        recognitionRequest.shouldReportPartialResults = true
        recognitionRequest.requiresOnDeviceRecognition = false

        recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            guard let self = self else { return }

            if let result = result {
                let transcription = result.bestTranscription.formattedString

                Task { @MainActor in
                    if result.isFinal {
                        self.transcribedText = transcription
                    } else {
                        self.partialTranscription = transcription
                    }
                }
            }

            if error != nil || result?.isFinal == true {
                // No audio engine to stop here; AudioCaptureService handles input
            }
        }
    }

    func appendAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        recognitionRequest?.append(buffer)
    }

    func stopRecognition() async -> String {
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()

        recognitionRequest = nil
        recognitionTask = nil

        // Wait for final transcription
        try? await Task.sleep(for: .milliseconds(500))

        let finalText = transcribedText.isEmpty ? partialTranscription : transcribedText
        return finalText
    }

    func transcribe(samples: [Float], sampleRate: Double) async throws -> String {
        guard let urlRecognitionRunner = resolvedURLRecognitionRunner(), urlRecognitionRunner.isAvailable else {
            throw SpeechRecognitionError.recognitionUnavailable
        }

        recognitionTask?.cancel()
        recognitionTask = nil
        finishURLRecognitionContinuation(.failure(CancellationError()))

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vvterm-transcription-\(UUID().uuidString)")
            .appendingPathExtension("caf")

        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let file = try AVAudioFile(forWriting: tempURL, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)

        if let channel = buffer.floatChannelData?.pointee {
            samples.withUnsafeBufferPointer { ptr in
                channel.update(from: ptr.baseAddress!, count: samples.count)
            }
        }

        try file.write(from: buffer)

        let request = SFSpeechURLRecognitionRequest(url: tempURL)
        request.shouldReportPartialResults = false
        request.requiresOnDeviceRecognition = false

        return try await withCheckedThrowingContinuation { continuation in
            let urlContinuation = URLRecognitionContinuation(
                tempURL: tempURL,
                continuation: continuation
            )
            urlRecognitionContinuation = urlContinuation

            recognitionTask = urlRecognitionRunner.startRecognition(with: request) { [weak self, weak urlContinuation] result, error in
                Task { @MainActor in
                    guard let self,
                          let urlContinuation,
                          self.urlRecognitionContinuation === urlContinuation else { return }

                    if let error {
                        self.finishURLRecognitionContinuation(.failure(error))
                        return
                    }

                    guard let result, result.isFinal else { return }
                    self.finishURLRecognitionContinuation(.success(result.bestTranscription.formattedString))
                }
            }
        }
    }

    func cancelRecognition() {
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        finishURLRecognitionContinuation(.failure(CancellationError()))

        recognitionRequest = nil
        recognitionTask = nil

        transcribedText = ""
        partialTranscription = ""
    }

    func resetTranscriptions() {
        transcribedText = ""
        partialTranscription = ""
    }

    private func finishURLRecognitionContinuation(_ result: Result<String, Error>) {
        guard let continuation = urlRecognitionContinuation else { return }
        urlRecognitionContinuation = nil
        recognitionTask = nil
        continuation.finish(result)
    }

    // MARK: - Errors

    enum SpeechRecognitionError: LocalizedError {
        case recognitionUnavailable

        var errorDescription: String? {
            switch self {
            case .recognitionUnavailable:
                return "Speech recognition is not available. Please enable Siri in System Settings > Siri & Spotlight."
            }
        }
    }
}

@MainActor
private final class URLRecognitionContinuation {
    private let tempURL: URL
    private var continuation: CheckedContinuation<String, Error>?

    init(tempURL: URL, continuation: CheckedContinuation<String, Error>) {
        self.tempURL = tempURL
        self.continuation = continuation
    }

    func finish(_ result: Result<String, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        try? FileManager.default.removeItem(at: tempURL)

        switch result {
        case .success(let text):
            continuation.resume(returning: text)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}
