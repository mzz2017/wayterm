//
//  TranscriptionSettingsView.swift
//  VVTerm
//

import SwiftUI

// MARK: - Transcription Settings View

struct TranscriptionSettingsView: View {
    @ObservedObject private var settingsStore: TranscriptionSettingsPreferenceStore
    @ObservedObject private var modelDownloads: VoiceModelDownloadStore
    @ObservedObject private var whisperManager: MLXModelManager
    @ObservedObject private var parakeetManager: MLXModelManager

    private let mlxAvailable = MLXAudioSupport.isSupported

    private let languages = [
        ("en", String(localized: "English")),
        ("es", String(localized: "Spanish")),
        ("fr", String(localized: "French")),
        ("de", String(localized: "German")),
        ("ja", String(localized: "Japanese")),
        ("zh", String(localized: "Chinese")),
        ("ko", String(localized: "Korean")),
        ("pt", String(localized: "Portuguese")),
        ("ru", String(localized: "Russian")),
        ("auto", String(localized: "Auto-detect"))
    ]

    init(
        settingsStore: TranscriptionSettingsPreferenceStore,
        modelDownloads: VoiceModelDownloadStore
    ) {
        _settingsStore = ObservedObject(wrappedValue: settingsStore)
        _modelDownloads = ObservedObject(wrappedValue: modelDownloads)
        _whisperManager = ObservedObject(wrappedValue: modelDownloads.whisperManager)
        _parakeetManager = ObservedObject(wrappedValue: modelDownloads.parakeetManager)
    }

    var body: some View {
        Form {
            Section {
                Toggle("Show voice input button", isOn: $settingsStore.terminalVoiceButtonEnabled)
            } header: {
                Text("Terminal")
            } footer: {
                Text("Cmd + Shift + M always works, even when the button is hidden.")
            }

            Section {
                Picker("Engine", selection: $settingsStore.providerRawValue) {
                    Text("System (Apple)").tag(TranscriptionProvider.system.rawValue)
                    #if arch(arm64)
                    if mlxAvailable {
                        Text("Whisper (MLX)").tag(TranscriptionProvider.mlxWhisper.rawValue)
                        Text("Parakeet (MLX)").tag(TranscriptionProvider.mlxParakeet.rawValue)
                    }
                    #endif
                }
            } header: {
                Text("Provider")
            } footer: {
                Text(providerDescription)
            }

            if settingsStore.providerRawValue == TranscriptionProvider.system.rawValue || settingsStore.providerRawValue == TranscriptionProvider.mlxWhisper.rawValue {
                Section {
                    Picker("Language", selection: $settingsStore.language) {
                        ForEach(languages, id: \.0) { code, name in
                            Text(name).tag(code)
                        }
                    }
                } header: {
                    Text("Language")
                } footer: {
                    if settingsStore.language == TranscriptionSettingsDefaults.autoLanguageCode {
                        if settingsStore.providerRawValue == TranscriptionProvider.system.rawValue {
                            Text("Auto-detect uses your device language.")
                        } else {
                            Text("Auto-detect identifies the spoken language before transcribing.")
                        }
                    }
                }
            }

            #if arch(arm64)
            if mlxAvailable && settingsStore.providerRawValue == TranscriptionProvider.mlxWhisper.rawValue {
                modelSection(
                    manager: whisperManager,
                    kind: .whisper,
                    modelBinding: $settingsStore.whisperModelId,
                    models: [
                        ("mlx-community/whisper-tiny-mlx", String(localized: "Tiny"), "~39 MB"),
                        ("mlx-community/whisper-base-mlx", String(localized: "Base"), "~74 MB"),
                        ("mlx-community/whisper-small-mlx", String(localized: "Small"), "~244 MB"),
                        ("mlx-community/whisper-medium-mlx-8bit", String(localized: "Medium (8-bit)"), "~400 MB"),
                        ("mlx-community/whisper-medium-mlx-q4", String(localized: "Medium (Q4)"), "~250 MB"),
                        ("mlx-community/whisper-medium-mlx-fp32", String(localized: "Medium (FP32)"), "~1.5 GB")
                    ]
                )
            }

            if mlxAvailable && settingsStore.providerRawValue == TranscriptionProvider.mlxParakeet.rawValue {
                modelSection(
                    manager: parakeetManager,
                    kind: .parakeetTDT,
                    modelBinding: $settingsStore.parakeetModelId,
                    models: [
                        ("mlx-community/parakeet-tdt-0.6b-v2", String(localized: "Parakeet TDT 0.6B"), "~600 MB")
                    ],
                    footnote: String(localized: "Parakeet supports English only.")
                )
            }
            #endif

            storageSection
        }
        .formStyle(.grouped)
        .onAppear {
            settingsStore.refreshFromPersistence(mlxAvailable: mlxAvailable)
            modelDownloads.setModelId(settingsStore.whisperModelId, for: .whisper)
            modelDownloads.setModelId(settingsStore.parakeetModelId, for: .parakeetTDT)
            modelDownloads.refreshStatuses()
        }
    }

    private var providerDescription: String {
        switch settingsStore.providerRawValue {
        case TranscriptionProvider.system.rawValue:
            return String(localized: "Uses Apple's built-in speech recognition. Requires network for best results.")
        case TranscriptionProvider.mlxWhisper.rawValue:
            return String(localized: "OpenAI Whisper runs locally using MLX. Works offline after download.")
        case TranscriptionProvider.mlxParakeet.rawValue:
            return String(localized: "NVIDIA Parakeet runs locally using MLX. Optimized for real-time transcription.")
        default:
            return ""
        }
    }

    @ViewBuilder
    private func modelSection(
        manager: MLXModelManager,
        kind: MLXModelKind,
        modelBinding: Binding<String>,
        models: [(String, String, String)],
        footnote: String? = nil
    ) -> some View {
        Section {
            Picker("Model", selection: modelBinding) {
                ForEach(models, id: \.0) { id, name, size in
                    HStack {
                        Text(name)
                        Spacer()
                        Text(size)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(id)
                }
            }
            .onChangeCompat(of: modelBinding.wrappedValue) { newValue in
                modelDownloads.setModelId(newValue, for: kind)
            }

            modelStatusRow(manager: manager)

            if case .downloading(let progress) = manager.state {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: progress.fraction)
                    HStack {
                        if progress.totalBytes > 0 {
                            Text(String(format: String(localized: "%@ / %@"),
                                        ByteCountFormatter.string(fromByteCount: progress.bytesDownloaded, countStyle: .file),
                                        ByteCountFormatter.string(fromByteCount: progress.totalBytes, countStyle: .file)))
                        } else {
                            Text("Downloading...")
                        }
                        Spacer()
                        if let eta = progress.estimatedSecondsRemaining, eta > 0 {
                            Text(formatETA(eta))
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            if manager.isModelAvailable {
                Button("Delete Model", role: .destructive) {
                    modelDownloads.removeModel(for: kind)
                }
                .padding(.top, 4)
            }
        } header: {
            Text("Model")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if let footnote {
                    Text(footnote)
                }
                if let repoSize = manager.repoSizeBytes {
                    Text(String(format: String(localized: "Download size: %@"),
                                ByteCountFormatter.string(fromByteCount: repoSize, countStyle: .file)))
                }
            }
        }
    }

    @ViewBuilder
    private func modelStatusRow(manager: MLXModelManager) -> some View {
        HStack {
            Text("Status")
            Spacer()
            switch manager.state {
            case .idle:
                Button("Download") {
                    modelDownloads.downloadModel(for: manager.kind)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            case .downloading:
                Text("Downloading...")
                    .foregroundStyle(.orange)
            case .ready:
                Label("Ready", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .failed(let error):
                VStack(alignment: .trailing, spacing: 4) {
                    Label("Failed", systemImage: "xmark.circle.fill")
                        .foregroundStyle(.red)
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func formatETA(_ seconds: Int) -> String {
        if seconds < 60 {
            return String(format: String(localized: "%llds remaining"), seconds)
        } else if seconds < 3600 {
            let minutes = seconds / 60
            return String(format: String(localized: "%lldm remaining"), minutes)
        } else {
            let hours = seconds / 3600
            let minutes = (seconds % 3600) / 60
            return String(format: String(localized: "%lldh %lldm remaining"), hours, minutes)
        }
    }

    @ViewBuilder
    private var storageSection: some View {
        #if arch(arm64)
        if mlxAvailable {
            let activeManager = settingsStore.providerRawValue == TranscriptionProvider.mlxWhisper.rawValue ? whisperManager : parakeetManager
            if activeManager.totalStorageBytes > 0 {
                Section("Storage") {
                    HStack {
                        Text("Model Storage")
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: activeManager.localStorageBytes, countStyle: .file))
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Total MLX Models")
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: activeManager.totalStorageBytes, countStyle: .file))
                            .foregroundStyle(.secondary)
                    }
                    Button("Clear All Storage", role: .destructive) {
                        modelDownloads.clearAllStorage()
                    }
                }
            }
        }
        #endif
    }
}
