import Foundation
import Combine
import os.log
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

@MainActor
protocol TerminalAccessoryCloudProfileSyncing {
    func syncTerminalAccessoryProfile(_ profile: TerminalAccessoryProfile) async throws -> TerminalAccessoryProfile
}

@MainActor
protocol TerminalAccessoryPendingSyncCoordinating {
    func enqueueTerminalAccessoryProfileUpsert(_ profile: TerminalAccessoryProfile)
    func drainPendingMutations() async
}

enum TerminalAccessoryCloudResolutionNotification {
    static let didResolve = Notification.Name("TerminalAccessoryProfileDidResolveFromCloudKit")
}

extension CloudKitSyncCoordinator: TerminalAccessoryPendingSyncCoordinating {
    func enqueueTerminalAccessoryProfileUpsert(_ profile: TerminalAccessoryProfile) {
        guard let payload = try? PendingCloudKitMutation.encodedPayload(for: profile) else { return }
        enqueuePendingMutation(
            .upsert(
                entity: .terminalAccessoryProfile,
                entityKey: TerminalAccessoryProfile.recordName,
                payload: payload
            )
        )
    }
}

@MainActor
private struct NoopTerminalAccessoryCloudProfileSync: TerminalAccessoryCloudProfileSyncing {
    func syncTerminalAccessoryProfile(_ profile: TerminalAccessoryProfile) async throws -> TerminalAccessoryProfile {
        profile
    }
}

@MainActor
private struct NoopTerminalAccessoryPendingSyncCoordinator: TerminalAccessoryPendingSyncCoordinating {
    func enqueueTerminalAccessoryProfileUpsert(_ profile: TerminalAccessoryProfile) {}
    func drainPendingMutations() async {}
}

@MainActor
struct TerminalAccessoryPreferencesDependencies {
    var isPro: @MainActor () -> Bool
    var trackCustomActionCreated: @MainActor (TerminalAccessoryCustomActionKind) -> Void
    var cloudProfileSync: any TerminalAccessoryCloudProfileSyncing
    var syncCoordinator: any TerminalAccessoryPendingSyncCoordinating

    init(
        isPro: @escaping @MainActor () -> Bool = { false },
        trackCustomActionCreated: @escaping @MainActor (TerminalAccessoryCustomActionKind) -> Void = { _ in },
        cloudProfileSync: (any TerminalAccessoryCloudProfileSyncing)? = nil,
        syncCoordinator: (any TerminalAccessoryPendingSyncCoordinating)? = nil
    ) {
        self.isPro = isPro
        self.trackCustomActionCreated = trackCustomActionCreated
        self.cloudProfileSync = cloudProfileSync ?? NoopTerminalAccessoryCloudProfileSync()
        self.syncCoordinator = syncCoordinator ?? NoopTerminalAccessoryPendingSyncCoordinator()
    }
}

@MainActor
final class TerminalAccessoryPreferencesManager: ObservableObject {
    static let shared = TerminalAccessoryPreferencesManager(dependencies: .live)

    @Published private(set) var profile: TerminalAccessoryProfile

    private let defaults: UserDefaults
    private let cloudProfileSync: any TerminalAccessoryCloudProfileSyncing
    private let syncCoordinator: any TerminalAccessoryPendingSyncCoordinating
    private let dependencies: TerminalAccessoryPreferencesDependencies
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "app.vivy.vvterm",
        category: "TerminalAccessoryPreferences"
    )

    private var foregroundObserver: NSObjectProtocol?
    private var syncToggleObserver: NSObjectProtocol?
    private var cloudResolutionObserver: NSObjectProtocol?
    private var startupCloudSyncTask: (id: UUID, task: Task<Void, Never>)?
    private var foregroundCloudSyncTask: (id: UUID, task: Task<Void, Never>)?
    private var syncToggleCloudSyncTask: (id: UUID, task: Task<Void, Never>)?
    private var cloudResolutionTask: (id: UUID, task: Task<Void, Never>)?
    private var pendingSyncTask: Task<Void, Never>?
    private var lastKnownSyncEnabled: Bool
    private var lastForegroundSyncAt: Date = .distantPast
    private let foregroundSyncMinimumInterval: TimeInterval = 20

    init(
        defaults: UserDefaults = .standard,
        cloudProfileSync: (any TerminalAccessoryCloudProfileSyncing)? = nil,
        syncCoordinator: (any TerminalAccessoryPendingSyncCoordinating)? = nil,
        dependencies: TerminalAccessoryPreferencesDependencies? = nil,
        startObservers: Bool = true,
        startInitialSync: Bool = true
    ) {
        let resolvedDependencies = dependencies ?? TerminalAccessoryPreferencesDependencies()
        self.defaults = defaults
        self.cloudProfileSync = cloudProfileSync ?? resolvedDependencies.cloudProfileSync
        self.syncCoordinator = syncCoordinator ?? resolvedDependencies.syncCoordinator
        self.dependencies = resolvedDependencies
        self.profile = TerminalAccessoryPreferencesManager.loadProfile(from: defaults)
        self.lastKnownSyncEnabled = SyncSettings.isEnabled

        if startObservers {
            observeForegroundSync()
            observeSyncToggleChanges()
            observeCloudResolutionChanges()
        }

        if startInitialSync {
            startStartupCloudSync()
        }
    }

    deinit {
        if let foregroundObserver {
            NotificationCenter.default.removeObserver(foregroundObserver)
        }
        if let syncToggleObserver {
            NotificationCenter.default.removeObserver(syncToggleObserver)
        }
        if let cloudResolutionObserver {
            NotificationCenter.default.removeObserver(cloudResolutionObserver)
        }
        startupCloudSyncTask?.task.cancel()
        foregroundCloudSyncTask?.task.cancel()
        syncToggleCloudSyncTask?.task.cancel()
        cloudResolutionTask?.task.cancel()
        pendingSyncTask?.cancel()
    }

    var activeItems: [TerminalAccessoryItemRef] {
        profile.layout.activeItems
    }

    var customActions: [TerminalAccessoryCustomAction] {
        profile.customActions
            .filter { !$0.isDeleted }
            .sorted { lhs, rhs in
                if lhs.updatedAt == rhs.updatedAt {
                    return lhs.id.uuidString < rhs.id.uuidString
                }
                return lhs.updatedAt > rhs.updatedAt
            }
    }

    var deletedCustomActions: [TerminalAccessoryCustomAction] {
        profile.customActions.filter(\.isDeleted)
    }

    var canCreateCustomAction: Bool {
        customActions.count < TerminalAccessoryProfile.maxCustomActions
    }

    /// Free tier is limited to `FreeTierLimits.maxCustomActions` created actions.
    /// Existing actions beyond the limit keep working; only creation is gated.
    var isCustomActionCreationProGated: Bool {
        !dependencies.isPro() && customActions.count >= FreeTierLimits.maxCustomActions
    }

    var customActionLimit: Int {
        dependencies.isPro() ? TerminalAccessoryProfile.maxCustomActions : FreeTierLimits.maxCustomActions
    }

    func customAction(for id: UUID) -> TerminalAccessoryCustomAction? {
        customActions.first { $0.id == id }
    }

    func createCustomAction(
        title: String,
        kind: TerminalAccessoryCustomActionKind,
        commandContent: String,
        commandSendMode: TerminalSnippetSendMode,
        shortcutKey: TerminalAccessoryShortcutKey,
        shortcutModifiers: TerminalAccessoryShortcutModifiers
    ) throws -> TerminalAccessoryCustomAction {
        guard canCreateCustomAction else {
            throw TerminalAccessoryValidationError.customActionLimitReached
        }
        guard !isCustomActionCreationProGated else {
            throw TerminalAccessoryValidationError.customActionProRequired
        }

        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCommandContent = commandContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            throw TerminalAccessoryValidationError.emptyTitle
        }
        if kind == .command && trimmedCommandContent.isEmpty {
            throw TerminalAccessoryValidationError.emptyCommandContent
        }

        let now = Date()
        let action = TerminalAccessoryCustomAction(
            title: String(trimmedTitle.prefix(TerminalAccessoryProfile.maxCustomActionTitleLength)),
            kind: kind,
            commandContent: kind == .command
                ? String(commandContent.prefix(TerminalAccessoryProfile.maxCommandContentLength))
                : "",
            commandSendMode: commandSendMode,
            shortcutKey: shortcutKey,
            shortcutModifiers: shortcutModifiers,
            updatedAt: now,
            deletedAt: nil
        )

        applyProfileMutation(at: now) { nextProfile, _ in
            nextProfile.customActions.insert(action, at: 0)
        }
        dependencies.trackCustomActionCreated(kind)
        return action
    }

    @discardableResult
    func updateCustomAction(
        id: UUID,
        title: String,
        kind: TerminalAccessoryCustomActionKind,
        commandContent: String,
        commandSendMode: TerminalSnippetSendMode,
        shortcutKey: TerminalAccessoryShortcutKey,
        shortcutModifiers: TerminalAccessoryShortcutModifiers
    ) throws -> TerminalAccessoryCustomAction {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCommandContent = commandContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            throw TerminalAccessoryValidationError.emptyTitle
        }
        if kind == .command && trimmedCommandContent.isEmpty {
            throw TerminalAccessoryValidationError.emptyCommandContent
        }

        guard let index = profile.customActions.firstIndex(where: { $0.id == id && !$0.isDeleted }) else {
            throw TerminalAccessoryValidationError.customActionNotFound
        }

        let now = Date()
        applyProfileMutation(at: now) { nextProfile, mutationDate in
            nextProfile.customActions[index].title = String(trimmedTitle.prefix(TerminalAccessoryProfile.maxCustomActionTitleLength))
            nextProfile.customActions[index].kind = kind
            nextProfile.customActions[index].commandContent = kind == .command
                ? String(commandContent.prefix(TerminalAccessoryProfile.maxCommandContentLength))
                : ""
            nextProfile.customActions[index].commandSendMode = commandSendMode
            nextProfile.customActions[index].shortcutKey = shortcutKey
            nextProfile.customActions[index].shortcutModifiers = shortcutModifiers
            nextProfile.customActions[index].updatedAt = mutationDate
            nextProfile.customActions[index].deletedAt = nil
        }
        let nextProfile = profile
        return nextProfile.customActions[index]
    }

    func deleteCustomAction(id: UUID) {
        guard let index = profile.customActions.firstIndex(where: { $0.id == id && !$0.isDeleted }) else {
            return
        }

        applyProfileMutation { nextProfile, now in
            nextProfile.customActions[index].title = ""
            nextProfile.customActions[index].commandContent = ""
            nextProfile.customActions[index].deletedAt = now
            nextProfile.customActions[index].updatedAt = now
        }
    }

    func moveActiveItems(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        let nextItems = moveItems(profile.layout.activeItems, fromOffsets: offsets, toOffset: destination)
        updateLayoutItems(nextItems)
    }

    func removeActiveItems(atOffsets offsets: IndexSet) {
        let nextItems = removeItems(profile.layout.activeItems, atOffsets: offsets)
        updateLayoutItems(nextItems)
    }

    func removeActiveItem(_ item: TerminalAccessoryItemRef) {
        var nextItems = profile.layout.activeItems
        nextItems.removeAll { $0 == item }
        updateLayoutItems(nextItems)
    }

    func addActiveItem(_ item: TerminalAccessoryItemRef) {
        guard !profile.layout.activeItems.contains(item) else { return }
        var nextItems = profile.layout.activeItems
        nextItems.append(item)
        updateLayoutItems(nextItems)
    }

    func resetToDefaultLayout() {
        updateLayout { layout in
            layout.activeItems = TerminalAccessoryProfile.defaultActiveItems
        }
    }

    func refreshFromCloud() async {
        await syncWithCloud()
    }

    private func startStartupCloudSync() {
        startupCloudSyncTask?.task.cancel()
        let taskID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            guard !Task.isCancelled else {
                self.clearStartupCloudSyncTask(id: taskID)
                return
            }
            await self.syncWithCloud()
            guard !Task.isCancelled, SyncSettings.isEnabled else {
                self.clearStartupCloudSyncTask(id: taskID)
                return
            }
            await self.syncCoordinator.drainPendingMutations()
            self.clearStartupCloudSyncTask(id: taskID)
        }
        startupCloudSyncTask = (taskID, task)
    }

    private func startForegroundCloudSync() {
        foregroundCloudSyncTask?.task.cancel()
        let taskID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            guard !Task.isCancelled else {
                self.clearForegroundCloudSyncTask(id: taskID)
                return
            }
            await self.syncWithCloudIfNeededForForeground()
            self.clearForegroundCloudSyncTask(id: taskID)
        }
        foregroundCloudSyncTask = (taskID, task)
    }

    private func startSyncToggleCloudSync() {
        syncToggleCloudSyncTask?.task.cancel()
        let taskID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            guard !Task.isCancelled else {
                self.clearSyncToggleCloudSyncTask(id: taskID)
                return
            }
            let isEnabled = SyncSettings.isEnabled
            guard isEnabled != self.lastKnownSyncEnabled else {
                self.clearSyncToggleCloudSyncTask(id: taskID)
                return
            }

            self.lastKnownSyncEnabled = isEnabled
            if isEnabled {
                guard !Task.isCancelled else {
                    self.clearSyncToggleCloudSyncTask(id: taskID)
                    return
                }
                await self.syncWithCloud()
            } else {
                self.cancelCloudSyncTasksForDisabledSync(currentToggleTaskID: taskID)
            }
            self.clearSyncToggleCloudSyncTask(id: taskID)
        }
        syncToggleCloudSyncTask = (taskID, task)
    }

    private func startCloudResolutionApply(_ resolvedProfile: TerminalAccessoryProfile) {
        cloudResolutionTask?.task.cancel()
        let taskID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            guard !Task.isCancelled else {
                self.clearCloudResolutionTask(id: taskID)
                return
            }
            guard SyncSettings.isEnabled else {
                self.clearCloudResolutionTask(id: taskID)
                return
            }
            let mergedWithCurrent = TerminalAccessoryProfile
                .merged(local: self.profile, remote: resolvedProfile)
                .normalized()
            self.applyProfile(mergedWithCurrent, scheduleCloudSync: false)
            self.clearCloudResolutionTask(id: taskID)
        }
        cloudResolutionTask = (taskID, task)
    }

    private func clearStartupCloudSyncTask(id: UUID) {
        guard startupCloudSyncTask?.id == id else { return }
        startupCloudSyncTask = nil
    }

    private func clearForegroundCloudSyncTask(id: UUID) {
        guard foregroundCloudSyncTask?.id == id else { return }
        foregroundCloudSyncTask = nil
    }

    private func clearSyncToggleCloudSyncTask(id: UUID) {
        guard syncToggleCloudSyncTask?.id == id else { return }
        syncToggleCloudSyncTask = nil
    }

    private func clearCloudResolutionTask(id: UUID) {
        guard cloudResolutionTask?.id == id else { return }
        cloudResolutionTask = nil
    }

    private func cancelCloudSyncTasksForDisabledSync(currentToggleTaskID: UUID? = nil) {
        startupCloudSyncTask?.task.cancel()
        foregroundCloudSyncTask?.task.cancel()
        if syncToggleCloudSyncTask?.id != currentToggleTaskID {
            syncToggleCloudSyncTask?.task.cancel()
        }
        cloudResolutionTask?.task.cancel()
        pendingSyncTask?.cancel()
        pendingSyncTask = nil
    }

    private func updateLayoutItems(_ items: [TerminalAccessoryItemRef]) {
        updateLayout { layout in
            layout.activeItems = items
        }
    }

    private func moveItems<T>(_ items: [T], fromOffsets offsets: IndexSet, toOffset destination: Int) -> [T] {
        var result = items
        let movingItems = offsets.map { result[$0] }
        for index in offsets.sorted(by: >) {
            result.remove(at: index)
        }

        var insertionIndex = destination
        let removedBeforeDestination = offsets.filter { $0 < destination }.count
        insertionIndex -= removedBeforeDestination
        insertionIndex = max(0, min(insertionIndex, result.count))
        result.insert(contentsOf: movingItems, at: insertionIndex)
        return result
    }

    private func removeItems<T>(_ items: [T], atOffsets offsets: IndexSet) -> [T] {
        var result = items
        for index in offsets.sorted(by: >) {
            guard result.indices.contains(index) else { continue }
            result.remove(at: index)
        }
        return result
    }

    private func updateLayout(_ update: (inout TerminalAccessoryLayout) -> Void) {
        applyProfileMutation { nextProfile, now in
            update(&nextProfile.layout)
            nextProfile.layout.updatedAt = now
        }
    }

    private func applyProfileMutation(
        at mutationDate: Date = Date(),
        scheduleCloudSync: Bool = true,
        _ mutate: (inout TerminalAccessoryProfile, Date) -> Void
    ) {
        var nextProfile = profile
        mutate(&nextProfile, mutationDate)
        nextProfile.updatedAt = mutationDate
        nextProfile.lastWriterDeviceId = DeviceIdentity.id
        applyProfile(nextProfile, scheduleCloudSync: scheduleCloudSync)
    }

    private func applyProfile(_ nextProfile: TerminalAccessoryProfile, scheduleCloudSync: Bool) {
        let normalizedProfile = nextProfile.normalized()
        guard normalizedProfile != profile else { return }

        profile = normalizedProfile
        persistProfile()
        publishProfileChange()

        if scheduleCloudSync {
            scheduleSyncWithCloud()
        }
    }

    private func publishProfileChange() {
        NotificationCenter.default.post(
            name: .terminalAccessoryProfileDidChange,
            object: self,
            userInfo: ["profile": profile]
        )
    }

    private func persistProfile() {
        do {
            let encoded = try JSONEncoder().encode(profile)
            defaults.set(encoded, forKey: TerminalAccessoryProfile.defaultsKey)
        } catch {
            logger.error("Failed to encode terminal accessory profile: \(error.localizedDescription)")
        }
    }

    private static func loadProfile(from defaults: UserDefaults) -> TerminalAccessoryProfile {
        guard let data = defaults.data(forKey: TerminalAccessoryProfile.defaultsKey) else {
            let defaultProfile = TerminalAccessoryProfile.defaultValue.normalized()
            if let encoded = try? JSONEncoder().encode(defaultProfile) {
                defaults.set(encoded, forKey: TerminalAccessoryProfile.defaultsKey)
            }
            return defaultProfile
        }

        do {
            let decoded = try JSONDecoder().decode(TerminalAccessoryProfile.self, from: data)
            let normalized = decoded.normalized()
            if normalized != decoded, let encoded = try? JSONEncoder().encode(normalized) {
                defaults.set(encoded, forKey: TerminalAccessoryProfile.defaultsKey)
            }
            return normalized
        } catch {
            let defaultProfile = TerminalAccessoryProfile.defaultValue.normalized()
            if let encoded = try? JSONEncoder().encode(defaultProfile) {
                defaults.set(encoded, forKey: TerminalAccessoryProfile.defaultsKey)
            }
            return defaultProfile
        }
    }

    private func scheduleSyncWithCloud() {
        pendingSyncTask?.cancel()
        pendingSyncTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 650_000_000)
            guard !Task.isCancelled else { return }
            await self?.enqueueProfileSync()
        }
    }

    private func enqueueProfileSync() async {
        guard SyncSettings.isEnabled else { return }
        syncCoordinator.enqueueTerminalAccessoryProfileUpsert(profile)
        await syncCoordinator.drainPendingMutations()
    }

    private func syncWithCloud() async {
        guard SyncSettings.isEnabled else { return }

        let localSnapshot = profile

        do {
            let cloudResolved = try await cloudProfileSync.syncTerminalAccessoryProfile(localSnapshot)
            guard !Task.isCancelled, SyncSettings.isEnabled else { return }
            let mergedWithCurrent = TerminalAccessoryProfile.merged(local: profile, remote: cloudResolved).normalized()
            applyProfile(mergedWithCurrent, scheduleCloudSync: false)
        } catch {
            logger.warning("Terminal accessory CloudKit sync failed: \(error.localizedDescription)")
        }
    }

    private func observeForegroundSync() {
        #if os(iOS)
        let name = UIApplication.didBecomeActiveNotification
        #elseif os(macOS)
        let name = NSApplication.didBecomeActiveNotification
        #else
        return
        #endif

        foregroundObserver = NotificationCenter.default.addObserver(
            forName: name,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // NotificationCenter delivers this observer on `.main`; keep it as an intent handoff.
            MainActor.assumeIsolated {
                self?.startForegroundCloudSync()
            }
        }
    }

    private func syncWithCloudIfNeededForForeground() async {
        let now = Date()
        guard now.timeIntervalSince(lastForegroundSyncAt) >= foregroundSyncMinimumInterval else {
            return
        }

        lastForegroundSyncAt = now
        await syncWithCloud()
        guard !Task.isCancelled, SyncSettings.isEnabled else { return }
        await syncCoordinator.drainPendingMutations()
    }

    private func observeSyncToggleChanges() {
        syncToggleObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: defaults,
            queue: .main
        ) { [weak self] _ in
            // NotificationCenter delivers this observer on `.main`; keep it as an intent handoff.
            MainActor.assumeIsolated {
                self?.startSyncToggleCloudSync()
            }
        }
    }

    private func observeCloudResolutionChanges() {
        cloudResolutionObserver = NotificationCenter.default.addObserver(
            forName: TerminalAccessoryCloudResolutionNotification.didResolve,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            // NotificationCenter delivers this observer on `.main`; keep it as an intent handoff.
            MainActor.assumeIsolated {
                let resolvedProfile = notification.userInfo?["profile"] as? TerminalAccessoryProfile
                guard let resolvedProfile else { return }
                self?.startCloudResolutionApply(resolvedProfile)
            }
        }
    }
}

#if DEBUG
extension TerminalAccessoryPreferencesManager {
    var hasPendingStartupCloudSyncForTesting: Bool {
        startupCloudSyncTask != nil
    }

    func waitForStartupCloudSyncForTesting() async {
        await startupCloudSyncTask?.task.value
    }
}
#endif
