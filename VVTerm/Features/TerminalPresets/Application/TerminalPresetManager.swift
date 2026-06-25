//
//  TerminalPresetManager.swift
//  aizen
//
//  Created by Uladzislau Yakauleu on 10.12.25.
//

import Foundation
import SwiftUI
import Combine
import os.log

extension Notification.Name {
    static let terminalPresetsDidChange = Notification.Name("terminalPresetsDidChange")
}

nonisolated final class TerminalPresetManager: ObservableObject {
    @MainActor
    static let shared = TerminalPresetManager()

    private let defaults: UserDefaults
    private let presetsKey = "terminalPresets"
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.aizen", category: "TerminalPresetManager")

    @MainActor
    @Published private(set) var presets: [TerminalPreset] = []

    @MainActor
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        loadPresets()
    }

    @MainActor
    private func loadPresets() {
        guard let data = defaults.data(forKey: presetsKey) else {
            presets = []
            return
        }

        do {
            let decoder = JSONDecoder()
            presets = try decoder.decode([TerminalPreset].self, from: data)
        } catch {
            logger.error("Failed to decode terminal presets: \(error.localizedDescription)")
            presets = []
        }
    }

    @MainActor
    private func savePresets() {
        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(presets)
            defaults.set(data, forKey: presetsKey)
            NotificationCenter.default.post(name: .terminalPresetsDidChange, object: nil)
        } catch {
            logger.error("Failed to encode terminal presets: \(error.localizedDescription)")
        }
    }

    @MainActor
    func addPreset(name: String, command: String, icon: String = "terminal") {
        let preset = TerminalPreset(
            name: name,
            command: command,
            icon: icon,
            isBuiltIn: false
        )
        presets.append(preset)
        savePresets()
    }

    @MainActor
    func updatePreset(_ preset: TerminalPreset) {
        guard let index = presets.firstIndex(where: { $0.id == preset.id }) else { return }
        presets[index] = preset
        savePresets()
    }

    @MainActor
    func deletePreset(id: UUID) {
        presets.removeAll { $0.id == id }
        savePresets()
    }

    @MainActor
    func movePreset(from source: IndexSet, to destination: Int) {
        presets.move(fromOffsets: source, toOffset: destination)
        savePresets()
    }
}
