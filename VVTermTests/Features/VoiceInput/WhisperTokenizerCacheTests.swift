import XCTest
@testable import VVTerm

// Test Context:
// These tests protect Whisper tokenizer encoding cache ownership. Tokenizer
// encodings are long-lived, shared VoiceInput resources loaded from bundled or
// downloaded tokenizer files, so concurrent model transcription setup must not
// race on a process-global mutable dictionary. Update these tests only if the
// tokenizer cache contract intentionally changes.

final class WhisperTokenizerCacheTests: XCTestCase {
    func testCacheLoadsEncodingOnceAcrossConcurrentCallers() {
        let cache = WhisperEncodingCache()
        let recorder = WhisperEncodingLoadRecorder()

        // Given multiple transcription setup paths request the same tokenizer
        // encoding at the same time.
        DispatchQueue.concurrentPerform(iterations: 32) { _ in
            _ = try? cache.encoding(named: "multilingual") {
                recorder.recordLoad()
                return Self.makeEncoding()
            }
        }

        // Then the cache owner serializes access and publishes one shared
        // encoding without racing the underlying tokenizer file load.
        XCTAssertEqual(
            recorder.loadCount,
            1,
            "Whisper tokenizer cache should load a shared encoding once across concurrent callers"
        )
    }

    func testCacheRetriesAfterLoadFailure() throws {
        let cache = WhisperEncodingCache()
        let recorder = WhisperEncodingLoadRecorder()

        // Given the first tokenizer resource load fails before an encoding can
        // be safely published.
        XCTAssertThrowsError(
            try cache.encoding(named: "gpt2") {
                recorder.recordLoad()
                throw WhisperTokenizerCacheTestError.loadFailed
            }
        )

        // When a later caller asks for the same encoding again.
        _ = try cache.encoding(named: "gpt2") {
            recorder.recordLoad()
            return Self.makeEncoding()
        }

        // Then failure is not cached as success; the next caller retries the
        // file load and publishes the successful encoding.
        XCTAssertEqual(
            recorder.loadCount,
            2,
            "Failed tokenizer loads must not mark the encoding as cached"
        )
    }

    private static func makeEncoding() -> WhisperEncoding {
        WhisperEncoding(
            baseTokens: [Data("token".utf8)],
            baseVocabCount: 1,
            specialTokens: ["<|endoftext|>": 1],
            nVocab: 2
        )
    }
}

private final class WhisperEncodingLoadRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var loadCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func recordLoad() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}

private enum WhisperTokenizerCacheTestError: Error {
    case loadFailed
}
