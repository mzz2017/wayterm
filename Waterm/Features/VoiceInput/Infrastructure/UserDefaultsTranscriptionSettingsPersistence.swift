import Foundation

@MainActor
final class UserDefaultsTranscriptionSettingsPersistence: TranscriptionSettingsPersisting {
    static let terminalVoiceButtonEnabledKey = "terminalVoiceButtonEnabled"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadMigratingLegacySettings(mlxAvailable: Bool) -> TranscriptionSettingsPreferenceSnapshot {
        let provider = migratedProvider(mlxAvailable: mlxAvailable)
        let whisperModelId = migratedWhisperModelId()
        let parakeetModelId = migratedParakeetModelId()
        let language = currentLanguage()
        let terminalVoiceButtonEnabled = defaults.object(forKey: Self.terminalVoiceButtonEnabledKey) as? Bool ?? true

        return TranscriptionSettingsPreferenceSnapshot(
            providerRawValue: provider.rawValue,
            whisperModelId: whisperModelId,
            parakeetModelId: parakeetModelId,
            language: language,
            terminalVoiceButtonEnabled: terminalVoiceButtonEnabled
        )
    }

    func setProviderRawValue(_ value: String) {
        defaults.set(value, forKey: TranscriptionSettingsKeys.provider)
    }

    func setWhisperModelId(_ value: String) {
        defaults.set(value, forKey: TranscriptionSettingsKeys.mlxWhisperModelId)
    }

    func setParakeetModelId(_ value: String) {
        defaults.set(value, forKey: TranscriptionSettingsKeys.mlxParakeetModelId)
    }

    func setLanguage(_ value: String) {
        defaults.set(value, forKey: TranscriptionSettingsKeys.language)
    }

    func setTerminalVoiceButtonEnabled(_ value: Bool) {
        defaults.set(value, forKey: Self.terminalVoiceButtonEnabledKey)
    }

    private func migratedProvider(mlxAvailable: Bool) -> TranscriptionProvider {
        let provider = currentProvider()
        if !mlxAvailable, provider != .system {
            defaults.set(TranscriptionProvider.system.rawValue, forKey: TranscriptionSettingsKeys.provider)
            return .system
        }
        defaults.set(provider.rawValue, forKey: TranscriptionSettingsKeys.provider)
        return provider
    }

    private func currentProvider() -> TranscriptionProvider {
        guard let raw = defaults.string(forKey: TranscriptionSettingsKeys.provider) else {
            return TranscriptionSettingsDefaults.provider
        }
        if let provider = TranscriptionProvider(rawValue: raw) {
            return provider
        }
        switch raw {
        case "whisper":
            return .mlxWhisper
        case "parakeet":
            return .mlxParakeet
        default:
            return TranscriptionSettingsDefaults.provider
        }
    }

    private func migratedWhisperModelId() -> String {
        let modelId: String
        if let current = defaults.string(forKey: TranscriptionSettingsKeys.mlxWhisperModelId) {
            modelId = current
        } else if let legacy = defaults.string(forKey: "whisperModelId") {
            modelId = legacy
        } else {
            modelId = TranscriptionSettingsDefaults.mlxWhisperModelId
        }

        let normalized = TranscriptionSettingsStore.normalizedWhisperModelId(modelId)
        defaults.set(normalized, forKey: TranscriptionSettingsKeys.mlxWhisperModelId)
        return normalized
    }

    private func migratedParakeetModelId() -> String {
        let modelId = defaults.string(forKey: TranscriptionSettingsKeys.mlxParakeetModelId)
            ?? defaults.string(forKey: "parakeetModelId")
            ?? TranscriptionSettingsDefaults.mlxParakeetModelId
        defaults.set(modelId, forKey: TranscriptionSettingsKeys.mlxParakeetModelId)
        return modelId
    }

    private func currentLanguage() -> String {
        let raw = defaults.string(forKey: TranscriptionSettingsKeys.language)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let raw, !raw.isEmpty else { return TranscriptionSettingsDefaults.language }
        return raw
    }
}
