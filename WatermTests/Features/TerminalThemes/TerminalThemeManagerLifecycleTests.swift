import Foundation
import Testing
@testable import Waterm
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

// Test Context:
// These tests protect custom terminal theme persistence and CloudKit sync
// lifecycle ownership. Creating, editing, and deleting custom themes are
// user-visible persistence actions, so TerminalThemeManager must report local
// persistence failures instead of publishing successful UI state, and any
// CloudKit push work it starts must be tracked and awaitable. Fakes keep
// UserDefaults, file storage, and sync drain behavior in memory; update this
// context only when custom-theme persistence ownership intentionally moves to
// another TerminalThemes application-layer type.
@Suite(.serialized)
@MainActor
struct TerminalThemeManagerLifecycleTests {
    @Test
    func createThemeDoesNotPublishOrSyncWhenLocalPersistenceFails() {
        // Given custom theme persistence rejects writes.
        let store = FakeTerminalThemeCustomThemeStore()
        let syncCoordinator = FakeTerminalThemeSyncCoordinator()
        let manager = makeManager(customThemeStore: store, syncCoordinator: syncCoordinator)
        store.saveError = FakeTerminalThemeStoreError.saveFailed

        // When Settings requests a custom theme create.
        #expect(throws: FakeTerminalThemeStoreError.saveFailed) {
            try manager.createCustomTheme(name: "Solar Build", content: validThemeContent())
        }

        // Then the manager must not publish a successful local state or enqueue
        // CloudKit work for a theme that was not durably persisted.
        #expect(manager.customThemes.isEmpty)
        #expect(syncCoordinator.enqueuedThemes.isEmpty)
        #expect(manager.pendingCloudSyncRequestIDs.isEmpty)
    }

    @Test
    func updateThemeRollsBackPublishedStateAndSkipsSyncWhenLocalPersistenceFails() {
        // Given a visible custom theme already loaded from local persistence.
        let original = TerminalTheme(
            name: "Original",
            content: validThemeContent(foreground: "#FFFFFF"),
            updatedAt: Date(timeIntervalSince1970: 1),
            deletedAt: nil
        )
        let store = FakeTerminalThemeCustomThemeStore(themes: [original])
        let syncCoordinator = FakeTerminalThemeSyncCoordinator()
        let manager = makeManager(customThemeStore: store, syncCoordinator: syncCoordinator)
        store.saveError = FakeTerminalThemeStoreError.saveFailed

        // When Settings requests an edit that cannot be persisted.
        #expect(throws: FakeTerminalThemeStoreError.saveFailed) {
            try manager.updateCustomTheme(
                id: original.id,
                name: "Renamed",
                content: validThemeContent(foreground: "#EEEEEE")
            )
        }

        // Then the visible theme remains the persisted version and no sync push
        // is launched for a failed local mutation.
        #expect(manager.customThemes == [original])
        #expect(syncCoordinator.enqueuedThemes.isEmpty)
        #expect(manager.pendingCloudSyncRequestIDs.isEmpty)
    }

    @Test
    func deleteThemeThrowsAndKeepsThemeVisibleWhenLocalPersistenceFails() {
        // Given a visible custom theme already loaded from local persistence.
        let original = TerminalTheme(
            name: "Disposable",
            content: validThemeContent(),
            updatedAt: Date(timeIntervalSince1970: 1),
            deletedAt: nil
        )
        let store = FakeTerminalThemeCustomThemeStore(themes: [original])
        let syncCoordinator = FakeTerminalThemeSyncCoordinator()
        let manager = makeManager(customThemeStore: store, syncCoordinator: syncCoordinator)
        store.saveError = FakeTerminalThemeStoreError.saveFailed

        // When Settings requests deletion and local persistence fails.
        #expect(throws: FakeTerminalThemeStoreError.saveFailed) {
            try manager.deleteCustomTheme(id: original.id)
        }

        // Then the theme is still visible and CloudKit is not asked to sync an
        // unpersisted tombstone.
        #expect(manager.customThemes == [original])
        #expect(syncCoordinator.enqueuedThemes.isEmpty)
        #expect(manager.pendingCloudSyncRequestIDs.isEmpty)
    }

    @Test
    func cloudSyncRequestIsTrackedUntilDrainFinishes() async throws {
        // Given CloudKit sync drain is delayed by the application-layer sync
        // coordinator.
        let store = FakeTerminalThemeCustomThemeStore()
        let syncCoordinator = FakeTerminalThemeSyncCoordinator()
        let manager = makeManager(customThemeStore: store, syncCoordinator: syncCoordinator)

        // When a custom theme is created successfully.
        let theme = try manager.createCustomTheme(name: "Tracked", content: validThemeContent())
        let requestID = try #require(manager.pendingCloudSyncRequestIDs.first)
        await syncCoordinator.waitUntilDrainStarted()

        // Then TerminalThemeManager exposes the in-flight CloudKit push instead
        // of dropping a fire-and-forget task.
        #expect(syncCoordinator.enqueuedThemes.map(\.id) == [theme.id])
        #expect(manager.pendingCloudSyncRequestIDs.contains(requestID))

        await syncCoordinator.finishDrain()
        await manager.waitForCloudSyncRequest(requestID)
        #expect(!manager.pendingCloudSyncRequestIDs.contains(requestID))
    }

    @Test
    func userDefaultsStoreDoesNotCommitDefaultsWhenFileSyncFails() throws {
        // Given the concrete custom-theme store points at a path that cannot be
        // used as a theme-file directory.
        let defaults = UserDefaults(suiteName: "TerminalThemeManagerLifecycleTests.\(UUID().uuidString)")!
        let storageKey = "terminalThemeManager.lifecycle.partialWrite"
        let blockingFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("TerminalThemeManagerLifecycleTests-\(UUID().uuidString)")
        try Data("not a directory".utf8).write(to: blockingFileURL)
        defer { try? FileManager.default.removeItem(at: blockingFileURL) }
        let store = UserDefaultsTerminalThemeCustomThemeStore(
            defaults: defaults,
            customThemesKey: storageKey,
            customThemesDirectoryURL: { blockingFileURL }
        )
        let theme = TerminalTheme(
            name: "Partial",
            content: validThemeContent(),
            updatedAt: Date(timeIntervalSince1970: 1),
            deletedAt: nil
        )

        // When file synchronization fails during save.
        #expect(throws: (any Error).self) {
            try store.saveThemes([theme])
        }

        // Then the UserDefaults payload must remain untouched so a failed
        // custom-theme mutation cannot appear successful on next launch.
        #expect(
            defaults.data(forKey: storageKey) == nil,
            "Custom theme defaults must not be committed before file sync succeeds."
        )
    }

    @Test
    func foregroundSyncRequestIsTrackedUntilDrainFinishes() async throws {
        // Given TerminalThemeManager observes foreground notifications and the
        // sync coordinator holds drain work open.
        let store = FakeTerminalThemeCustomThemeStore()
        let syncCoordinator = FakeTerminalThemeSyncCoordinator()
        let manager = TerminalThemeManager(
            defaults: UserDefaults(suiteName: "TerminalThemeManagerLifecycleTests.\(UUID().uuidString)")!,
            cloudStore: FakeTerminalThemeCloudStore(),
            syncCoordinator: syncCoordinator,
            customThemeStore: store,
            startsCloudSyncOnInitialization: false,
            observesSystemNotifications: true
        )

        // When the platform foreground notification arrives.
        NotificationCenter.default.post(name: foregroundNotificationName(), object: nil)
        await syncCoordinator.waitUntilDrainStarted()
        let requestID = try #require(manager.pendingCloudSyncRequestIDs.first)

        // Then foreground sync is tracked by the same application owner instead
        // of being hidden in a notification Task.
        #expect(manager.pendingCloudSyncRequestIDs.contains(requestID))

        await syncCoordinator.finishDrain()
        await manager.waitForCloudSyncRequest(requestID)
        #expect(!manager.pendingCloudSyncRequestIDs.contains(requestID))
    }

    @Test
    func notificationObserverTokensInvalidateCallbacksExactlyOnce() {
        let notificationCenter = NotificationCenter()
        let notificationName = Notification.Name("TerminalThemeManagerLifecycleTests.observer")
        let observerTokens = TerminalThemeNotificationObserverTokens(notificationCenter: notificationCenter)
        let receipts = TerminalThemeNotificationReceiptCounter()

        // Given TerminalThemeManager owns NotificationCenter tokens through a
        // separate lifecycle owner that can be invalidated from deinit.
        let token = notificationCenter.addObserver(forName: notificationName, object: nil, queue: nil) { _ in
            receipts.record()
        }
        observerTokens.append(token)

        // When notifications are posted before and after invalidation.
        notificationCenter.post(name: notificationName, object: nil)
        observerTokens.invalidateAll()
        observerTokens.invalidateAll()
        notificationCenter.post(name: notificationName, object: nil)

        // Then the callback is removed once and repeated teardown remains
        // idempotent.
        #expect(receipts.count == 1)
    }

    @Test
    func liveCloudStorePolicyStaysOutsideCoreCloudKitManager() throws {
        let root = try sourceRoot()
        let managerSource = try source(
            at: root.appendingPathComponent("Waterm/Features/TerminalThemes/Application/TerminalThemeManager.swift")
        )
        let cloudStoreSource = try source(
            at: root.appendingPathComponent("Waterm/Features/TerminalThemes/Infrastructure/TerminalThemeCloudStore.swift")
        )

        #expect(
            managerSource.contains("cloudStore ?? TerminalThemeCloudKitStore(cloudKit: CloudKitManager.shared)"),
            "TerminalThemeManager default wiring should use the feature-owned CloudKit adapter."
        )
        #expect(
            cloudStoreSource.contains("final class TerminalThemeCloudKitStore"),
            "Terminal theme CloudKit record policy should live in a feature-owned adapter."
        )
        #expect(
            !cloudStoreSource.contains("extension CloudKitManager: TerminalThemeCloudStoring"),
            "TerminalThemes should not attach feature cloud-store policy to the Core CloudKitManager type."
        )
    }

    private func foregroundNotificationName() -> Notification.Name {
        #if os(iOS)
        UIApplication.didBecomeActiveNotification
        #elseif os(macOS)
        NSApplication.didBecomeActiveNotification
        #else
        Notification.Name("TerminalThemeManagerLifecycleTestsForeground")
        #endif
    }

    private func makeManager(
        customThemeStore: FakeTerminalThemeCustomThemeStore,
        syncCoordinator: FakeTerminalThemeSyncCoordinator
    ) -> TerminalThemeManager {
        TerminalThemeManager(
            defaults: UserDefaults(suiteName: "TerminalThemeManagerLifecycleTests.\(UUID().uuidString)")!,
            cloudStore: FakeTerminalThemeCloudStore(),
            syncCoordinator: syncCoordinator,
            customThemeStore: customThemeStore,
            startsCloudSyncOnInitialization: false,
            observesSystemNotifications: false
        )
    }

    private func validThemeContent(foreground: String = "#FFFFFF") -> String {
        """
        background = #000000
        foreground = \(foreground)
        """
    }

    private func source(at url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    private func sourceRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.lastPathComponent != "WatermTests" {
            let next = url.deletingLastPathComponent()
            if next.path == url.path {
                throw SourceRootError.notFound
            }
            url = next
        }
        return url.deletingLastPathComponent()
    }

    private enum SourceRootError: Error {
        case notFound
    }
}

@MainActor
private final class FakeTerminalThemeCustomThemeStore: TerminalThemeCustomThemeStoring {
    private(set) var themes: [TerminalTheme]
    private(set) var savedSnapshots: [[TerminalTheme]] = []
    var saveError: Error?

    init(themes: [TerminalTheme] = []) {
        self.themes = themes
    }

    func loadThemes() throws -> [TerminalTheme] {
        themes
    }

    func saveThemes(_ themes: [TerminalTheme]) throws {
        if let saveError {
            throw saveError
        }
        self.themes = themes
        savedSnapshots.append(themes)
    }
}

@MainActor
private final class FakeTerminalThemeCloudStore: TerminalThemeCloudStoring {
    var remoteThemes: [TerminalTheme] = []
    var remotePreference: TerminalThemePreference?

    func fetchTerminalThemes() async throws -> [TerminalTheme] {
        remoteThemes
    }

    func fetchTerminalThemePreference() async throws -> TerminalThemePreference? {
        remotePreference
    }
}

@MainActor
private final class FakeTerminalThemeSyncCoordinator: TerminalThemeSyncCoordinating {
    private let drainGate = TerminalThemeLifecycleGate()
    private(set) var enqueuedThemes: [TerminalTheme] = []
    private(set) var enqueuedPreferences: [TerminalThemePreference] = []

    func enqueueTerminalThemeUpsert(_ theme: TerminalTheme) {
        enqueuedThemes.append(theme)
    }

    func enqueueTerminalThemePreferenceUpsert(_ preference: TerminalThemePreference) {
        enqueuedPreferences.append(preference)
    }

    func drainPendingMutations() async {
        await drainGate.markStartedAndWait()
    }

    func waitUntilDrainStarted() async {
        await drainGate.waitUntilStarted()
    }

    func finishDrain() async {
        await drainGate.open()
    }
}

private actor TerminalThemeLifecycleGate {
    private var started = false
    private var isOpen = false
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var openWaiters: [CheckedContinuation<Void, Never>] = []

    func markStartedAndWait() async {
        started = true
        let waiters = startedWaiters
        startedWaiters.removeAll()
        waiters.forEach { $0.resume() }

        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            openWaiters.append(continuation)
        }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { continuation in
            startedWaiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let waiters = openWaiters
        openWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private final class TerminalThemeNotificationReceiptCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var receivedCount = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return receivedCount
    }

    func record() {
        lock.lock()
        receivedCount += 1
        lock.unlock()
    }
}

private enum FakeTerminalThemeStoreError: Error, Equatable {
    case saveFailed
}
