import XCTest
@testable import VVTerm

// Test Context:
// These tests protect voice-input transcription settings persistence and defaults.
// Fakes use isolated settings storage and no microphone or ML model; update only
// when transcription settings behavior intentionally changes.

final class TranscriptionSettingsStoreTests: XCTestCase {
    override func setUp() {
        super.setUp()
        clearKeys()
    }

    override func tearDown() {
        clearKeys()
        super.tearDown()
    }

    func testCurrentProviderDefaultsToSystem() {
        XCTAssertEqual(TranscriptionSettingsStore.currentProvider(), .system)
    }

    func testCurrentProviderSupportsLegacyRawValues() {
        UserDefaults.standard.set("whisper", forKey: TranscriptionSettingsKeys.provider)
        XCTAssertEqual(TranscriptionSettingsStore.currentProvider(), .mlxWhisper)

        UserDefaults.standard.set("parakeet", forKey: TranscriptionSettingsKeys.provider)
        XCTAssertEqual(TranscriptionSettingsStore.currentProvider(), .mlxParakeet)
    }

    func testCurrentWhisperModelIdFallsBackToLegacyKeyAndNormalizesSuffix() {
        UserDefaults.standard.set("mlx-community/whisper-small", forKey: "whisperModelId")

        XCTAssertEqual(
            TranscriptionSettingsStore.currentWhisperModelId(),
            "mlx-community/whisper-small-mlx"
        )
    }

    func testCurrentWhisperModelIdMapsMediumModelTo8BitVariant() {
        UserDefaults.standard.set(
            "mlx-community/whisper-medium-mlx",
            forKey: TranscriptionSettingsKeys.mlxWhisperModelId
        )

        XCTAssertEqual(
            TranscriptionSettingsStore.currentWhisperModelId(),
            "mlx-community/whisper-medium-mlx-8bit"
        )
    }

    func testCurrentParakeetModelIdFallsBackToLegacyKey() {
        UserDefaults.standard.set("legacy/parakeet-model", forKey: "parakeetModelId")

        XCTAssertEqual(
            TranscriptionSettingsStore.currentParakeetModelId(),
            "legacy/parakeet-model"
        )
    }

    private func clearKeys() {
        let defaults = UserDefaults.standard
        [
            TranscriptionSettingsKeys.provider,
            TranscriptionSettingsKeys.mlxWhisperModelId,
            TranscriptionSettingsKeys.mlxParakeetModelId,
            "whisperModelId",
            "parakeetModelId",
        ].forEach(defaults.removeObject(forKey:))
    }
}
