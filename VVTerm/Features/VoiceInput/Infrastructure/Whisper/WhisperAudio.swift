import Foundation
#if arch(arm64)
import MLX
import MLXFFT

enum WhisperAudioConstants {
    nonisolated static let sampleRate = 16_000
    nonisolated static let nFFT = 400
    nonisolated static let hopLength = 160
    nonisolated static let chunkLength = 30
    nonisolated static let nSamples = chunkLength * sampleRate
    nonisolated static let nFrames = nSamples / hopLength
}

enum WhisperAudioError: LocalizedError {
    case missingMelFilters
    case invalidNpy

    var errorDescription: String? {
        switch self {
        case .missingMelFilters:
            return "Missing mel filter resource"
        case .invalidNpy:
            return "Invalid mel filter file"
        }
    }
}

nonisolated final class WhisperAudioProcessor {
    private static var melFiltersCache: MLXArray?

    static func logMelSpectrogram(_ samples: [Float], nMels: Int = 80, padding: Int = 0) throws -> MLXArray {
        var audio = MLXArray(samples, [samples.count])
        if padding > 0 {
            audio = padded(audio, widths: [IntOrPair((0, padding))])
        }

        let window = hanning(WhisperAudioConstants.nFFT)
        let freqs = stft(audio, window: window, nperseg: WhisperAudioConstants.nFFT, noverlap: WhisperAudioConstants.hopLength)

        let frameCount = max(freqs.dim(0) - 1, 0)
        let magnitudes = abs(freqs[0 ..< frameCount, .ellipsis]).square()

        let filters = try melFilters(nMels)
        let melSpec = matmul(magnitudes, filters.T)

        var logSpec = maximum(melSpec, MLXArray(1e-10))
        logSpec = log10(logSpec)
        let maxVal = logSpec.max()
        logSpec = maximum(logSpec, maxVal - MLXArray(8.0))
        logSpec = (logSpec + 4.0) / 4.0
        return logSpec
    }

    static func padOrTrim(_ array: MLXArray, length: Int, axis: Int = -1) -> MLXArray {
        let resolvedAxis = axis < 0 ? array.ndim + axis : axis
        let current = array.dim(resolvedAxis)
        if current > length {
            var indices: [MLXArrayIndex] = []
            indices.reserveCapacity(array.ndim)
            for axisIndex in 0..<array.ndim {
                if axisIndex == resolvedAxis {
                    indices.append(0 ..< length)
                } else {
                    indices.append(0 ..< array.dim(axisIndex))
                }
            }
            return array[indices]
        }

        if current < length {
            var widths: [IntOrPair] = Array(repeating: IntOrPair((0, 0)), count: array.ndim)
            widths[resolvedAxis] = IntOrPair((0, length - current))
            return padded(array, widths: widths)
        }

        return array
    }

    private static func melFilters(_ nMels: Int) throws -> MLXArray {
        if let cached = melFiltersCache { return cached }

        guard nMels == 80 else { throw WhisperAudioError.invalidNpy }

        guard let url = resourceURL(name: "mel_80", fileExtension: "npy") else {
            throw WhisperAudioError.missingMelFilters
        }

        let data = try Data(contentsOf: url)
        let header: WhisperNpyHeaderParser.Header
        do {
            header = try WhisperNpyHeaderParser.parse(data)
        } catch {
            throw WhisperAudioError.invalidNpy
        }
        guard header.shape == [80, 201] else { throw WhisperAudioError.invalidNpy }

        let raw = data.subdata(in: header.dataOffset ..< data.count)
        let array = MLXArray(raw, header.shape, dtype: .float32)
        melFiltersCache = array
        return array
    }

    private static func hanning(_ size: Int) -> MLXArray {
        let n = size
        let indices = MLXArray(0 ..< n).asType(.float32)
        let twoPi = Float.pi * 2
        let window = 0.5 - 0.5 * cos(indices * (twoPi / Float(n)))
        return window
    }

    private static func reflectPad(_ array: MLXArray, padding: Int) -> MLXArray {
        guard padding > 0 else { return array }
        let count = array.dim(0)
        if count <= padding + 1 {
            return padded(array, widths: [IntOrPair((padding, padding))], mode: .edge)
        }
        let prefixSlice = array[1 ..< (padding + 1)]
        let suffixStart = max(count - padding - 1, 0)
        let suffixSlice = array[suffixStart ..< (count - 1)]
        let prefix = prefixSlice[.stride(by: -1)]
        let suffix = suffixSlice[.stride(by: -1)]
        return concatenated([prefix, array, suffix], axis: 0)
    }

    private static func stft(
        _ x: MLXArray,
        window: MLXArray,
        nperseg: Int,
        noverlap: Int,
        nfft: Int? = nil
    ) -> MLXArray {
        let nfft = nfft ?? nperseg
        let padding = nperseg / 2
        let paddedX = reflectPad(x, padding: padding)

        let stride = noverlap
        let t = (paddedX.size - nperseg + noverlap) / noverlap
        let shape = [t, nfft]
        let strides = [stride, 1]
        let framed = asStrided(paddedX, shape, strides: strides)
        return rfft(framed * window)
    }

    private static func resourceURL(name: String, fileExtension: String) -> URL? {
        if let url = Bundle.main.url(forResource: name, withExtension: fileExtension, subdirectory: "Whisper") {
            return url
        }
        if let url = Bundle.main.url(forResource: name, withExtension: fileExtension, subdirectory: "Resources/Whisper") {
            return url
        }
        return Bundle.main.url(forResource: name, withExtension: fileExtension)
    }
}
#endif
