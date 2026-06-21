import XCTest
@testable import VVTerm

// Test Context:
// These tests protect the MLX model catalog used by on-device voice input. They
// use static catalog metadata and do not download models; update only when the
// supported model catalog intentionally changes.

final class MLXModelCatalogTests: XCTestCase {
    func testOptionLookupTrimsWhitespace() {
        let option = MLXModelCatalog.option(
            for: "  mlx-community/whisper-tiny-mlx \n",
            kind: .whisper
        )

        XCTAssertEqual(option?.id, "mlx-community/whisper-tiny-mlx")
        XCTAssertEqual(option?.kind, .whisper)
    }

    func testOptionLookupRespectsModelKind() {
        XCTAssertNil(
            MLXModelCatalog.option(
                for: "mlx-community/parakeet-tdt-0.6b-v2",
                kind: .whisper
            )
        )
    }

    func testAllOptionsIncludesWhisperAndParakeetPresets() {
        XCTAssertEqual(MLXModelCatalog.allOptions.count, 8)
        XCTAssertTrue(MLXModelCatalog.allOptions.contains { $0.kind == .whisper })
        XCTAssertTrue(MLXModelCatalog.allOptions.contains { $0.kind == .parakeetTDT })
    }
}
