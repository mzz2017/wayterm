//
//  TerminalThemeManager.swift
//  VVTerm
//

import Foundation
import Combine
import os.log
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

@MainActor
protocol TerminalThemeCustomThemeStoring {
    func loadThemes() throws -> [TerminalTheme]
    func saveThemes(_ themes: [TerminalTheme]) throws
}

@MainActor
protocol TerminalThemeCloudStoring {
    func fetchTerminalThemes() async throws -> [TerminalTheme]
    func fetchTerminalThemePreference() async throws -> TerminalThemePreference?
}

@MainActor
protocol TerminalThemeSyncCoordinating {
    func enqueueTerminalThemeUpsert(_ theme: TerminalTheme)
    func enqueueTerminalThemePreferenceUpsert(_ preference: TerminalThemePreference)
    func drainPendingMutations() async
}

extension CloudKitSyncCoordinator: TerminalThemeSyncCoordinating {
    func enqueueTerminalThemeUpsert(_ theme: TerminalTheme) {
        guard let payload = try? PendingCloudKitMutation.encodedPayload(for: theme) else { return }
        enqueuePendingMutation(.upsert(entity: .terminalTheme, entityKey: theme.id.uuidString, payload: payload))
    }

    func enqueueTerminalThemePreferenceUpsert(_ preference: TerminalThemePreference) {
        guard let payload = try? PendingCloudKitMutation.encodedPayload(for: preference) else { return }
        enqueuePendingMutation(
            .upsert(
                entity: .terminalThemePreference,
                entityKey: TerminalThemePreference.recordName,
                payload: payload
            )
        )
    }
}

@MainActor
final class UserDefaultsTerminalThemeCustomThemeStore: TerminalThemeCustomThemeStoring {
    private let defaults: UserDefaults
    private let customThemesKey: String
    private let fileManager: FileManager
    private let customThemesDirectoryURL: () -> URL
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "app.vivy.vvterm",
        category: "TerminalThemeStore"
    )

    init(
        defaults: UserDefaults,
        customThemesKey: String,
        fileManager: FileManager = .default,
        customThemesDirectoryURL: @escaping () -> URL = TerminalThemeStoragePaths.customThemesDirectoryURL
    ) {
        self.defaults = defaults
        self.customThemesKey = customThemesKey
        self.fileManager = fileManager
        self.customThemesDirectoryURL = customThemesDirectoryURL
    }

    func loadThemes() throws -> [TerminalTheme] {
        guard let data = defaults.data(forKey: customThemesKey) else {
            return []
        }
        return try JSONDecoder().decode([TerminalTheme].self, from: data)
    }

    func saveThemes(_ themes: [TerminalTheme]) throws {
        let data = try JSONEncoder().encode(themes)
        try syncCustomThemeFiles(themes)
        defaults.set(data, forKey: customThemesKey)
    }

    private func syncCustomThemeFiles(_ themes: [TerminalTheme]) throws {
        let directoryURL = customThemesDirectoryURL()
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let visibleThemes = themes.filter { !$0.isDeleted }
        let visibleNames = Set(visibleThemes.map(\.name))

        let existingFiles = try fileManager.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil)
        for file in existingFiles {
            guard !visibleNames.contains(file.lastPathComponent) else { continue }
            do {
                try fileManager.removeItem(at: file)
            } catch {
                logger.error("Failed to remove stale custom theme file \(file.lastPathComponent): \(error.localizedDescription)")
                throw error
            }
        }

        for theme in visibleThemes {
            let fileURL = directoryURL.appendingPathComponent(theme.name)
            try theme.content.write(to: fileURL, atomically: true, encoding: .utf8)
        }
    }
}

@MainActor
final class TerminalThemeManager: ObservableObject {
    static let shared = TerminalThemeManager()

    @Published private(set) var customThemes: [TerminalTheme] = []

    private struct PreferenceSnapshot: Equatable {
        var darkThemeName: String
        var lightThemeName: String
        var usePerAppearanceTheme: Bool
    }

    private let defaults: UserDefaults
    private let cloudStore: any TerminalThemeCloudStoring
    private let syncCoordinator: any TerminalThemeSyncCoordinating
    private let customThemeStore: any TerminalThemeCustomThemeStoring
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "app.vivy.vvterm", category: "TerminalThemeManager")

    private let darkThemeKey = CloudKitSyncConstants.terminalThemeNameKey
    private let lightThemeKey = CloudKitSyncConstants.terminalThemeNameLightKey
    private let perAppearanceThemeKey = CloudKitSyncConstants.terminalUsePerAppearanceThemeKey
    private let preferenceUpdatedAtKey = CloudKitSyncConstants.terminalThemePreferenceUpdatedAtKey

    nonisolated private let observerTokens = TerminalThemeNotificationObserverTokens()
    private var lastKnownPreferenceSnapshot: PreferenceSnapshot
    private var lastForegroundSyncAt: Date = .distantPast
    private var isApplyingRemotePreference = false
    private var pendingPreferenceSyncTask: Task<Void, Never>?
    private var pendingCloudSyncTasks: [UUID: Task<Void, Never>] = [:]
    private let foregroundSyncMinimumInterval: TimeInterval = 20

    var pendingCloudSyncRequestIDs: Set<UUID> {
        Set(pendingCloudSyncTasks.keys)
    }

    init(
        defaults: UserDefaults = .standard,
        cloudStore: (any TerminalThemeCloudStoring)? = nil,
        syncCoordinator: (any TerminalThemeSyncCoordinating)? = nil,
        customThemeStore: (any TerminalThemeCustomThemeStoring)? = nil,
        startsCloudSyncOnInitialization: Bool = true,
        observesSystemNotifications: Bool = true
    ) {
        self.defaults = defaults
        self.cloudStore = cloudStore ?? TerminalThemeCloudKitStore(cloudKit: CloudKitManager.shared)
        self.syncCoordinator = syncCoordinator ?? CloudKitSyncCoordinator.shared
        self.customThemeStore = customThemeStore ?? UserDefaultsTerminalThemeCustomThemeStore(
            defaults: defaults,
            customThemesKey: CloudKitSyncConstants.terminalCustomThemesStorageKey
        )
        self.lastKnownPreferenceSnapshot = PreferenceSnapshot(
            darkThemeName: defaults.string(forKey: darkThemeKey) ?? "Aizen Dark",
            lightThemeName: defaults.string(forKey: lightThemeKey) ?? "Aizen Light",
            usePerAppearanceTheme: defaults.object(forKey: perAppearanceThemeKey) as? Bool ?? true
        )

        loadThemes()
        syncLoadedCustomThemeFiles()
        ensureThemeSelectionIsValid()

        if observesSystemNotifications {
            observeThemePreferenceChanges()
            observeForegroundSync()
        }

        if startsCloudSyncOnInitialization {
            requestCloudSync {
                await self.syncFromCloud()
                await self.syncCoordinator.drainPendingMutations()
            }
        }
    }

    deinit {
        observerTokens.invalidateAll()
        pendingPreferenceSyncTask?.cancel()
        pendingCloudSyncTasks.values.forEach { $0.cancel() }
    }

    var customThemeNames: [String] {
        customThemes
            .filter { !$0.isDeleted }
            .map(\.name)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    nonisolated static func builtInThemeNames() -> [String] {
        guard let resourcePath = Bundle.main.resourcePath else { return [] }
        let fm = FileManager.default

        let structuredPath = (resourcePath as NSString).appendingPathComponent("ghostty/themes")
        if fm.fileExists(atPath: structuredPath),
           let files = try? fm.contentsOfDirectory(atPath: structuredPath) {
            return files
                .filter { file in
                    let fullPath = (structuredPath as NSString).appendingPathComponent(file)
                    var isDir: ObjCBool = false
                    fm.fileExists(atPath: fullPath, isDirectory: &isDir)
                    return !isDir.boolValue && !file.hasPrefix(".")
                }
                .sorted()
        }

        guard let files = try? fm.contentsOfDirectory(atPath: resourcePath) else { return [] }
        let knownNonThemes = Set([
            "Info", "Assets", "PkgInfo", "ghostty", "xterm-ghostty",
            "CodeSignature", "embedded", "_CodeSignature"
        ])
        return files
            .filter { file in
                let fullPath = (resourcePath as NSString).appendingPathComponent(file)
                var isDir: ObjCBool = false
                fm.fileExists(atPath: fullPath, isDirectory: &isDir)
                guard !isDir.boolValue else { return false }
                guard !file.hasPrefix(".") else { return false }
                guard !file.contains(".") else { return false }
                guard !knownNonThemes.contains(file) else { return false }
                return true
            }
            .sorted()
    }

    func suggestThemeName(from sourceName: String?) -> String {
        let trimmed = sourceName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            return uniqueThemeName(from: "Custom Theme")
        }
        let sanitized = sanitizeThemeName(trimmed)
        return uniqueThemeName(from: sanitized.isEmpty ? "Custom Theme" : sanitized)
    }

    func createCustomTheme(name: String, content: String) throws -> TerminalTheme {
        let normalizedContent = try TerminalThemeValidator.validateAndNormalizeThemeContent(content)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TerminalThemeValidationError.invalidName }
        let sanitized = sanitizeThemeName(trimmed)
        guard !sanitized.isEmpty else { throw TerminalThemeValidationError.invalidName }
        let finalName = uniqueThemeName(from: sanitized)

        let theme = TerminalTheme(
            name: finalName,
            content: normalizedContent,
            updatedAt: Date(),
            deletedAt: nil
        )

        let updatedThemes = customThemes + [theme]
        try persistCustomThemes(updatedThemes)
        ensureThemeSelectionIsValid()
        requestThemeCloudSync(theme)
        return theme
    }

    @discardableResult
    func updateCustomTheme(id: UUID, name: String, content: String) throws -> TerminalTheme {
        guard let index = customThemes.firstIndex(where: { $0.id == id && !$0.isDeleted }) else {
            throw TerminalThemeValidationError.themeNotFound
        }

        let normalizedContent = try TerminalThemeValidator.validateAndNormalizeThemeContent(content)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TerminalThemeValidationError.invalidName }

        let sanitized = sanitizeThemeName(trimmed)
        guard !sanitized.isEmpty else { throw TerminalThemeValidationError.invalidName }

        let previousName = customThemes[index].name
        let finalName = uniqueThemeName(from: sanitized, excludingThemeID: id)
        let now = Date()

        var updatedThemes = customThemes
        updatedThemes[index].name = finalName
        updatedThemes[index].content = normalizedContent
        updatedThemes[index].updatedAt = now
        updatedThemes[index].deletedAt = nil

        try persistCustomThemes(updatedThemes)
        migrateSelectionsForRenamedTheme(from: previousName, to: finalName)
        ensureThemeSelectionIsValid()
        pushThemeToCloud(customThemes[index])

        return customThemes[index]
    }

    func deleteCustomTheme(named name: String) throws {
        guard let index = customThemes.firstIndex(where: { $0.name == name && !$0.isDeleted }) else {
            return
        }

        try deleteTheme(at: index)
    }

    func deleteCustomTheme(id: UUID) throws {
        guard let index = customThemes.firstIndex(where: { $0.id == id && !$0.isDeleted }) else {
            return
        }

        try deleteTheme(at: index)
    }

    private func deleteTheme(at index: Int) throws {
        var updatedThemes = customThemes
        updatedThemes[index].deletedAt = Date()
        updatedThemes[index].updatedAt = Date()
        try persistCustomThemes(updatedThemes)
        ensureThemeSelectionIsValid()
        pushThemeToCloud(customThemes[index])
    }

    private func loadThemes() {
        do {
            customThemes = try customThemeStore.loadThemes()
        } catch {
            customThemes = []
            logger.error("Failed to load custom themes: \(error.localizedDescription)")
        }
    }

    private func syncLoadedCustomThemeFiles() {
        do {
            try customThemeStore.saveThemes(customThemes)
        } catch {
            logger.error("Failed to sync loaded custom theme files: \(error.localizedDescription)")
        }
    }

    private func persistCustomThemes(_ themes: [TerminalTheme]) throws {
        do {
            try customThemeStore.saveThemes(themes)
            customThemes = themes
        } catch {
            logger.error("Failed to save custom themes: \(error.localizedDescription)")
            throw error
        }
    }

    private func ensureThemeSelectionIsValid() {
        let available = Set(Self.builtInThemeNames() + customThemeNames)
        let fallbackDark = "Aizen Dark"
        let fallbackLight = "Aizen Light"

        let darkTheme = defaults.string(forKey: darkThemeKey) ?? fallbackDark
        let lightTheme = defaults.string(forKey: lightThemeKey) ?? fallbackLight

        var changed = false
        if !available.contains(darkTheme) {
            defaults.set(fallbackDark, forKey: darkThemeKey)
            changed = true
        }
        if !available.contains(lightTheme) {
            defaults.set(fallbackLight, forKey: lightThemeKey)
            changed = true
        }

        if changed {
            lastKnownPreferenceSnapshot = currentPreferenceSnapshot()
        }
    }

    private func sanitizeThemeName(_ name: String) -> String {
        var sanitized = name.replacingOccurrences(of: "/", with: "-")
        sanitized = sanitized.replacingOccurrences(of: ":", with: "-")
        sanitized = sanitized.replacingOccurrences(of: "\n", with: " ")
        sanitized = sanitized.replacingOccurrences(of: "\r", with: " ")
        sanitized = sanitized.replacingOccurrences(of: "\t", with: " ")
        return sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func uniqueThemeName(from baseName: String, excludingThemeID: UUID? = nil) -> String {
        let builtIn = Set(Self.builtInThemeNames().map(normalizedThemeNameKey(_:)))
        let existing = Set(
            customThemes
                .filter { !$0.isDeleted && $0.id != excludingThemeID }
                .map { normalizedThemeNameKey($0.name) }
        )
        let maxLength = 80

        var root = String(baseName.prefix(maxLength)).trimmingCharacters(in: .whitespacesAndNewlines)
        if root.isEmpty { root = "Custom Theme" }

        if !builtIn.contains(normalizedThemeNameKey(root)) &&
            !existing.contains(normalizedThemeNameKey(root)) {
            return root
        }

        var index = 2
        while true {
            let suffix = " \(index)"
            let availableRootLength = max(1, maxLength - suffix.count)
            let candidateRoot = String(root.prefix(availableRootLength)).trimmingCharacters(in: .whitespacesAndNewlines)
            let candidate = "\(candidateRoot)\(suffix)"
            if !builtIn.contains(normalizedThemeNameKey(candidate)) &&
                !existing.contains(normalizedThemeNameKey(candidate)) {
                return candidate
            }
            index += 1
        }
    }

    private func normalizedThemeNameKey(_ name: String) -> String {
        name
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }

    private func migrateSelectionsForRenamedTheme(from oldName: String, to newName: String) {
        guard oldName != newName else { return }

        if defaults.string(forKey: darkThemeKey) == oldName {
            defaults.set(newName, forKey: darkThemeKey)
        }

        if defaults.string(forKey: lightThemeKey) == oldName {
            defaults.set(newName, forKey: lightThemeKey)
        }
    }

    private func observeThemePreferenceChanges() {
        let token = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: defaults,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleThemePreferenceChange()
            }
        }
        observerTokens.append(token)
    }

    private func observeForegroundSync() {
        #if os(iOS)
        let name = UIApplication.didBecomeActiveNotification
        #elseif os(macOS)
        let name = NSApplication.didBecomeActiveNotification
        #else
        return
        #endif

        let token = NotificationCenter.default.addObserver(
            forName: name,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.requestForegroundCloudSyncIfNeeded()
            }
        }
        observerTokens.append(token)
    }

    private func requestForegroundCloudSyncIfNeeded() {
        let now = Date()
        guard now.timeIntervalSince(lastForegroundSyncAt) >= foregroundSyncMinimumInterval else {
            return
        }

        lastForegroundSyncAt = now
        requestCloudSync {
            await self.syncFromCloud()
            await self.syncCoordinator.drainPendingMutations()
        }
    }

    private func handleThemePreferenceChange() {
        guard !isApplyingRemotePreference else { return }
        let snapshot = currentPreferenceSnapshot()
        guard snapshot != lastKnownPreferenceSnapshot else { return }
        lastKnownPreferenceSnapshot = snapshot

        let now = Date()
        defaults.set(now.timeIntervalSince1970, forKey: preferenceUpdatedAtKey)
        schedulePreferenceCloudSync(
            TerminalThemePreference(
                darkThemeName: snapshot.darkThemeName,
                lightThemeName: snapshot.lightThemeName,
                usePerAppearanceTheme: snapshot.usePerAppearanceTheme,
                updatedAt: now
            )
        )
    }

    private func currentPreferenceSnapshot() -> PreferenceSnapshot {
        PreferenceSnapshot(
            darkThemeName: defaults.string(forKey: darkThemeKey) ?? "Aizen Dark",
            lightThemeName: defaults.string(forKey: lightThemeKey) ?? "Aizen Light",
            usePerAppearanceTheme: defaults.object(forKey: perAppearanceThemeKey) as? Bool ?? true
        )
    }

    private func localPreferenceUpdatedAt() -> Date {
        let value = defaults.double(forKey: preferenceUpdatedAtKey)
        guard value > 0 else { return .distantPast }
        return Date(timeIntervalSince1970: value)
    }

    private func schedulePreferenceCloudSync(_ preference: TerminalThemePreference) {
        pendingPreferenceSyncTask?.cancel()
        pendingPreferenceSyncTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            self?.requestPreferenceCloudSync(preference)
        }
    }

    private func pushThemeToCloud(_ theme: TerminalTheme) {
        requestThemeCloudSync(theme)
    }

    @discardableResult
    private func requestThemeCloudSync(_ theme: TerminalTheme) -> UUID? {
        guard SyncSettings.isEnabled else { return nil }
        return requestCloudSync {
            self.syncCoordinator.enqueueTerminalThemeUpsert(theme)
            await self.syncCoordinator.drainPendingMutations()
        }
    }

    @discardableResult
    private func requestPreferenceCloudSync(_ preference: TerminalThemePreference) -> UUID? {
        guard SyncSettings.isEnabled else { return nil }
        return requestCloudSync {
            self.syncCoordinator.enqueueTerminalThemePreferenceUpsert(preference)
            await self.syncCoordinator.drainPendingMutations()
        }
    }

    @discardableResult
    private func requestCloudSync(_ operation: @escaping @MainActor @Sendable () async -> Void) -> UUID {
        let requestID = UUID()
        let task = Task { @MainActor [weak self] in
            defer {
                self?.pendingCloudSyncTasks.removeValue(forKey: requestID)
            }
            await operation()
        }
        pendingCloudSyncTasks[requestID] = task
        return requestID
    }

    func waitForCloudSyncRequest(_ requestID: UUID) async {
        await pendingCloudSyncTasks[requestID]?.value
    }

    private func syncFromCloud() async {
        guard SyncSettings.isEnabled else { return }

        do {
            let localSnapshot = customThemes
            let remoteThemes = try await cloudStore.fetchTerminalThemes()
            let remoteByID = Dictionary(uniqueKeysWithValues: remoteThemes.map { ($0.id, $0) })

            mergeRemoteThemes(remoteThemes)

            for localTheme in localSnapshot {
                if let remoteTheme = remoteByID[localTheme.id],
                   remoteTheme.updatedAt >= localTheme.updatedAt {
                    continue
                }
                pushThemeToCloud(localTheme)
            }

            if let remotePreference = try await cloudStore.fetchTerminalThemePreference() {
                applyRemotePreferenceIfNewer(remotePreference)
            } else {
                let localUpdatedAt = localPreferenceUpdatedAt()
                let seedUpdatedAt: Date
                if localUpdatedAt == .distantPast {
                    seedUpdatedAt = Date()
                    defaults.set(seedUpdatedAt.timeIntervalSince1970, forKey: preferenceUpdatedAtKey)
                } else {
                    seedUpdatedAt = localUpdatedAt
                }

                let localPreference = TerminalThemePreference(
                    darkThemeName: currentPreferenceSnapshot().darkThemeName,
                    lightThemeName: currentPreferenceSnapshot().lightThemeName,
                    usePerAppearanceTheme: currentPreferenceSnapshot().usePerAppearanceTheme,
                    updatedAt: seedUpdatedAt
                )
                requestPreferenceCloudSync(localPreference)
            }
        } catch {
            logger.warning("Custom theme CloudKit sync failed: \(error.localizedDescription)")
        }
    }

    private func mergeRemoteThemes(_ remoteThemes: [TerminalTheme]) {
        var localByID = Dictionary(uniqueKeysWithValues: customThemes.map { ($0.id, $0) })

        for remoteTheme in remoteThemes {
            if let localTheme = localByID[remoteTheme.id] {
                if remoteTheme.updatedAt > localTheme.updatedAt {
                    localByID[remoteTheme.id] = remoteTheme
                }
            } else {
                localByID[remoteTheme.id] = remoteTheme
            }
        }

        let mergedThemes = Array(localByID.values)
        do {
            try persistCustomThemes(mergedThemes)
        } catch {
            logger.error("Failed to persist merged custom themes: \(error.localizedDescription)")
        }
        ensureThemeSelectionIsValid()
    }

    private func applyRemotePreferenceIfNewer(_ preference: TerminalThemePreference) {
        let localUpdatedAt = localPreferenceUpdatedAt()
        guard preference.updatedAt > localUpdatedAt else { return }

        isApplyingRemotePreference = true
        defaults.set(preference.darkThemeName, forKey: darkThemeKey)
        defaults.set(preference.lightThemeName, forKey: lightThemeKey)
        defaults.set(preference.usePerAppearanceTheme, forKey: perAppearanceThemeKey)
        defaults.set(preference.updatedAt.timeIntervalSince1970, forKey: preferenceUpdatedAtKey)
        isApplyingRemotePreference = false

        ensureThemeSelectionIsValid()
        lastKnownPreferenceSnapshot = currentPreferenceSnapshot()
    }
}
