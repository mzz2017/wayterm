import AVFoundation
import Foundation

nonisolated final class AudioConverterInputBufferProvider: @unchecked Sendable {
    private let lock = NSLock()
    private let buffer: AVAudioPCMBuffer
    private var didProvideBuffer = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func makeInputBlock() -> AVAudioConverterInputBlock {
        { [self] _, outStatus in
            return self.nextBuffer(outStatus: outStatus)
        }
    }

    private func nextBuffer(outStatus: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        lock.lock()
        defer { lock.unlock() }

        guard !didProvideBuffer else {
            outStatus.pointee = .noDataNow
            return nil
        }

        didProvideBuffer = true
        outStatus.pointee = .haveData
        return buffer
    }
}
