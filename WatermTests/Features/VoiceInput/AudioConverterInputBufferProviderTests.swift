import AVFoundation
import Testing
@testable import Waterm

// Test Context:
// These tests protect the VoiceInput audio conversion boundary. AVAudioEngine
// tap buffers are AVFoundation-owned and non-Sendable, so AudioCaptureService
// must hand them to AVAudioConverter through a small synchronous owner instead
// of capturing mutable buffer state directly in @Sendable converter callbacks.
// Update these tests only if AVAudioConverter input ownership intentionally
// changes.

struct AudioConverterInputBufferProviderTests {
    @Test
    func inputBlockProvidesTapBufferOnceThenReportsNoData() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8))
        let provider = AudioConverterInputBufferProvider(buffer: buffer)
        let inputBlock = provider.makeInputBlock()

        // When AVAudioConverter asks for input for the current conversion.
        var firstStatus = AVAudioConverterInputStatus.noDataNow
        let firstBuffer = inputBlock(8, &firstStatus)

        // Then the tap buffer is synchronously handed off once.
        #expect(firstBuffer === buffer)
        #expect(firstStatus == .haveData)

        // And repeated input requests for the same conversion report no data
        // instead of reusing the same mutable AVAudioPCMBuffer indefinitely.
        var secondStatus = AVAudioConverterInputStatus.haveData
        let secondBuffer = inputBlock(8, &secondStatus)
        #expect(secondBuffer == nil)
        #expect(secondStatus == .noDataNow)
    }
}
