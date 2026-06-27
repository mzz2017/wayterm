import Foundation
import Testing
@testable import VVTerm

// Test Context:
// Protects the VoiceInput settings preference boundary used by Settings UI.
// The UI should receive editable state from an application store while this store
// owns UserDefaults migration, unsupported-provider fallback, and write-through.
// Update these tests only when the persisted key migration or provider fallback
// policy intentionally changes.
@Suite
@MainActor
struct TranscriptionSettingsPreferenceStoreTests {
    private let defaults = UserDefaults.standard

    @Test
    func legacySettingsAreMigratedBeforeSettingsUIReadsThem() {
        clearKeys()
        defer { clearKeys() }

        // Given legacy settings from older transcription UI keys.
        defaults.set("whisper", forKey: TranscriptionSettingsKeys.provider)
        defaults.set("mlx-community/whisper-small", forKey: "whisperModelId")
        defaults.set("legacy/parakeet", forKey: "parakeetModelId")

        // When the application settings store loads the persisted state.
        let store = makeStore(mlxAvailable: true)

        // Then the UI-facing state and persisted values use the current keys and model IDs.
        #expect(store.providerRawValue == TranscriptionProvider.mlxWhisper.rawValue)
        #expect(store.whisperModelId == "mlx-community/whisper-small-mlx")
        #expect(store.parakeetModelId == "legacy/parakeet")
        #expect(
            defaults.string(forKey: TranscriptionSettingsKeys.provider) == TranscriptionProvider.mlxWhisper.rawValue,
            "Legacy provider values should be written back in the current raw-value format."
        )
        #expect(
            defaults.string(forKey: TranscriptionSettingsKeys.mlxWhisperModelId) == "mlx-community/whisper-small-mlx",
            "Legacy Whisper model IDs should be migrated to the current key and normalized."
        )
        #expect(
            defaults.string(forKey: TranscriptionSettingsKeys.mlxParakeetModelId) == "legacy/parakeet",
            "Legacy Parakeet model IDs should be migrated to the current key."
        )
    }

    @Test
    func unavailableMLXForcesSystemProviderAndPersistsUserChanges() {
        clearKeys()
        defer { clearKeys() }

        // Given an MLX provider selected on a device where MLX is unavailable.
        defaults.set(TranscriptionProvider.mlxParakeet.rawValue, forKey: TranscriptionSettingsKeys.provider)

        // When the settings store loads and the user edits preferences.
        let store = makeStore(mlxAvailable: false)
        store.language = "auto"
        store.terminalVoiceButtonEnabled = false

        // Then the provider falls back to system and subsequent UI edits persist through the store.
        #expect(store.providerRawValue == TranscriptionProvider.system.rawValue)
        #expect(
            defaults.string(forKey: TranscriptionSettingsKeys.provider) == TranscriptionProvider.system.rawValue,
            "Unsupported MLX providers should not remain persisted on unsupported devices."
        )
        #expect(defaults.string(forKey: TranscriptionSettingsKeys.language) == "auto")
        #expect(
            defaults.bool(forKey: UserDefaultsTranscriptionSettingsPersistence.terminalVoiceButtonEnabledKey) == false
        )
    }

    private func makeStore(mlxAvailable: Bool) -> TranscriptionSettingsPreferenceStore {
        TranscriptionSettingsPreferenceStore(
            persistence: UserDefaultsTranscriptionSettingsPersistence(defaults: defaults),
            mlxAvailable: mlxAvailable
        )
    }

    private func clearKeys() {
        [
            TranscriptionSettingsKeys.provider,
            TranscriptionSettingsKeys.mlxWhisperModelId,
            TranscriptionSettingsKeys.mlxParakeetModelId,
            TranscriptionSettingsKeys.language,
            UserDefaultsTranscriptionSettingsPersistence.terminalVoiceButtonEnabledKey,
            "whisperModelId",
            "parakeetModelId",
        ].forEach(defaults.removeObject(forKey:))
    }
}
