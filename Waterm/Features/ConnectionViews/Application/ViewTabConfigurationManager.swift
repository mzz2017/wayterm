//
//  ViewTabConfigurationManager.swift
//  Waterm
//

import Foundation
import SwiftUI
import Combine
import os.log

extension Notification.Name {
    static let viewTabConfigurationDidChange = Notification.Name("viewTabConfigurationDidChange")
}

nonisolated final class ViewTabConfigurationManager: ObservableObject {
    @MainActor
    static let shared = ViewTabConfigurationManager()

    private let defaults: UserDefaults
    private let orderKey = "connectionViewTabOrder"
    private let defaultTabKey = "connectionDefaultViewTab"
    private let showStatsKey = "showStatsTab"
    private let showTerminalKey = "showTerminalTab"
    private let showFilesKey = "showFilesTab"
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.vivy.waterm", category: "ViewTabConfigurationManager")

    @MainActor @Published private(set) var tabOrder: [ConnectionViewTab] = ConnectionViewTab.defaultOrder
    @MainActor @Published private(set) var defaultTab: String = "stats"
    @MainActor @Published private(set) var showStatsTab: Bool = true
    @MainActor @Published private(set) var showTerminalTab: Bool = true
    @MainActor @Published private(set) var showFilesTab: Bool = true

    @MainActor
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        loadConfiguration()
    }

    // MARK: - Load/Save

    @MainActor
    private func loadConfiguration() {
        loadTabOrder()
        loadDefaultTab()
        loadVisibility()
    }

    @MainActor
    private func loadTabOrder() {
        guard let data = defaults.data(forKey: orderKey),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else {
            tabOrder = ConnectionViewTab.defaultOrder
            return
        }

        // Rebuild order from stored IDs, validating each exists
        var order: [ConnectionViewTab] = []
        for id in decoded {
            if let tab = ConnectionViewTab.from(id: id) {
                order.append(tab)
            }
        }

        // Add any missing tabs at the end (future-proofing)
        for defaultTab in ConnectionViewTab.defaultOrder {
            if !order.contains(defaultTab) {
                order.append(defaultTab)
            }
        }

        tabOrder = order
    }

    @MainActor
    private func loadDefaultTab() {
        if let stored = defaults.string(forKey: defaultTabKey),
           ConnectionViewTab.from(id: stored) != nil {
            defaultTab = stored
        } else {
            defaultTab = "stats"
        }
    }

    @MainActor
    private func loadVisibility() {
        showStatsTab = defaults.object(forKey: showStatsKey) as? Bool ?? true
        showTerminalTab = defaults.object(forKey: showTerminalKey) as? Bool ?? true
        showFilesTab = defaults.object(forKey: showFilesKey) as? Bool ?? true

        if currentVisibleTabs.isEmpty {
            showStatsTab = true
            showTerminalTab = true
            showFilesTab = true
        }
    }

    @MainActor
    private func saveTabOrder() {
        do {
            let ids = tabOrder.map { $0.id }
            let data = try JSONEncoder().encode(ids)
            defaults.set(data, forKey: orderKey)
            NotificationCenter.default.post(name: .viewTabConfigurationDidChange, object: nil)
        } catch {
            logger.error("Failed to encode tab order: \(error.localizedDescription)")
        }
    }

    @MainActor
    private func saveDefaultTab() {
        defaults.set(defaultTab, forKey: defaultTabKey)
        NotificationCenter.default.post(name: .viewTabConfigurationDidChange, object: nil)
    }

    @MainActor
    private func saveVisibility() {
        defaults.set(showStatsTab, forKey: showStatsKey)
        defaults.set(showTerminalTab, forKey: showTerminalKey)
        defaults.set(showFilesTab, forKey: showFilesKey)
        NotificationCenter.default.post(name: .viewTabConfigurationDidChange, object: nil)
    }

    // MARK: - Public API

    @MainActor
    func moveTab(from source: IndexSet, to destination: Int) {
        tabOrder.move(fromOffsets: source, toOffset: destination)
        saveTabOrder()
    }

    @MainActor
    func setDefaultTab(_ tabId: String) {
        guard ConnectionViewTab.from(id: tabId) != nil else { return }
        defaultTab = tabId
        saveDefaultTab()
    }

    @MainActor
    func setVisibility(for tabId: String, isVisible: Bool) {
        guard ConnectionViewTab.from(id: tabId) != nil else { return }

        if !isVisible, isTabVisible(tabId) {
            guard currentVisibleTabs.count > 1 else { return }
        }

        switch tabId {
        case ConnectionViewTab.stats.id:
            showStatsTab = isVisible
        case ConnectionViewTab.terminal.id:
            showTerminalTab = isVisible
        case ConnectionViewTab.files.id:
            showFilesTab = isVisible
        default:
            return
        }

        if currentVisibleTabs.isEmpty {
            showStatsTab = true
            showTerminalTab = true
            showFilesTab = true
        }

        saveVisibility()
    }

    @MainActor
    func resetToDefaults() {
        tabOrder = ConnectionViewTab.defaultOrder
        defaultTab = "stats"
        showStatsTab = true
        showTerminalTab = true
        showFilesTab = true
        saveTabOrder()
        saveDefaultTab()
        saveVisibility()
    }

    /// Returns the first tab from the configured order
    @MainActor
    func firstTab() -> String {
        tabOrder.first?.id ?? "stats"
    }

    /// Returns the effective default tab
    @MainActor
    func effectiveDefaultTab() -> String {
        effectiveDefaultTab(showStats: showStatsTab, showTerminal: showTerminalTab, showFiles: showFilesTab)
    }

    /// Returns the effective default tab, accounting for visibility
    @MainActor
    func effectiveDefaultTab(showStats: Bool, showTerminal: Bool, showFiles: Bool = true) -> String {
        let isVisible: Bool
        switch defaultTab {
        case "stats": isVisible = showStats
        case "terminal": isVisible = showTerminal
        case "files": isVisible = showFiles
        default: isVisible = false
        }

        if isVisible {
            return defaultTab
        }

        // Default tab is hidden, fall back to first visible
        return firstVisibleTab(showStats: showStats, showTerminal: showTerminal, showFiles: showFiles)
    }

    /// Returns the first visible tab from the configured order
    @MainActor
    func firstVisibleTab(showStats: Bool, showTerminal: Bool, showFiles: Bool = true) -> String {
        for tab in tabOrder {
            switch tab.id {
            case "stats" where showStats: return "stats"
            case "terminal" where showTerminal: return "terminal"
            case "files" where showFiles: return "files"
            default: continue
            }
        }
        return currentVisibleTabs.first?.id ?? "stats"
    }

    /// Returns only visible tabs in order
    @MainActor
    func visibleTabs(showStats: Bool, showTerminal: Bool, showFiles: Bool = true) -> [ConnectionViewTab] {
        tabOrder.filter { tab in
            switch tab.id {
            case "stats": return showStats
            case "terminal": return showTerminal
            case "files": return showFiles
            default: return false
            }
        }
    }

    @MainActor
    var currentVisibleTabs: [ConnectionViewTab] {
        visibleTabs(showStats: showStatsTab, showTerminal: showTerminalTab, showFiles: showFilesTab)
    }

    @MainActor
    func isTabVisible(_ tabId: String) -> Bool {
        switch tabId {
        case ConnectionViewTab.stats.id:
            return showStatsTab
        case ConnectionViewTab.terminal.id:
            return showTerminalTab
        case ConnectionViewTab.files.id:
            return showFilesTab
        default:
            return false
        }
    }

    @MainActor
    func effectiveView(for storedView: String?) -> String {
        guard let storedView, ConnectionViewTab.from(id: storedView) != nil else {
            return effectiveDefaultTab()
        }

        guard isTabVisible(storedView) else {
            return effectiveDefaultTab()
        }

        return storedView
    }

    @MainActor
    func visibilityBinding(for tabId: String) -> Binding<Bool> {
        Binding(
            get: { [weak self] in
                self?.isTabVisible(tabId) ?? false
            },
            set: { [weak self] newValue in
                self?.setVisibility(for: tabId, isVisible: newValue)
            }
        )
    }

    @MainActor
    func defaultTabBinding() -> Binding<String> {
        Binding(
            get: { [weak self] in
                self?.effectiveDefaultTab() ?? "stats"
            },
            set: { [weak self] newValue in
                self?.setDefaultTab(newValue)
            }
        )
    }
}
