import Combine
import Foundation

struct TranscriptionSettingsPreferenceSnapshot: Equatable {
    var providerRawValue: String
    var whisperModelId: String
    var parakeetModelId: String
    var language: String
    var terminalVoiceButtonEnabled: Bool
}

@MainActor
protocol TranscriptionSettingsPersisting: AnyObject {
    func loadMigratingLegacySettings(mlxAvailable: Bool) -> TranscriptionSettingsPreferenceSnapshot
    func setProviderRawValue(_ value: String)
    func setWhisperModelId(_ value: String)
    func setParakeetModelId(_ value: String)
    func setLanguage(_ value: String)
    func setTerminalVoiceButtonEnabled(_ value: Bool)
}

@MainActor
final class TranscriptionSettingsPreferenceStore: ObservableObject {
    @Published var providerRawValue: String {
        didSet { persistence.setProviderRawValue(providerRawValue) }
    }

    @Published var whisperModelId: String {
        didSet { persistence.setWhisperModelId(whisperModelId) }
    }

    @Published var parakeetModelId: String {
        didSet { persistence.setParakeetModelId(parakeetModelId) }
    }

    @Published var language: String {
        didSet { persistence.setLanguage(language) }
    }

    @Published var terminalVoiceButtonEnabled: Bool {
        didSet { persistence.setTerminalVoiceButtonEnabled(terminalVoiceButtonEnabled) }
    }

    private let persistence: any TranscriptionSettingsPersisting

    init(
        persistence: any TranscriptionSettingsPersisting,
        mlxAvailable: Bool
    ) {
        self.persistence = persistence
        let snapshot = persistence.loadMigratingLegacySettings(mlxAvailable: mlxAvailable)
        providerRawValue = snapshot.providerRawValue
        whisperModelId = snapshot.whisperModelId
        parakeetModelId = snapshot.parakeetModelId
        language = snapshot.language
        terminalVoiceButtonEnabled = snapshot.terminalVoiceButtonEnabled
    }

    func refreshFromPersistence(mlxAvailable: Bool) {
        let snapshot = persistence.loadMigratingLegacySettings(mlxAvailable: mlxAvailable)
        providerRawValue = snapshot.providerRawValue
        whisperModelId = snapshot.whisperModelId
        parakeetModelId = snapshot.parakeetModelId
        language = snapshot.language
        terminalVoiceButtonEnabled = snapshot.terminalVoiceButtonEnabled
    }
}
