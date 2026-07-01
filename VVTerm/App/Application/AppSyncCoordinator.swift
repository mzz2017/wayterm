import Foundation
import os.log

@MainActor
final class AppSyncCoordinator {
    enum ServerRefreshReason {
        case foreground
        case remoteNotification
        case settingsEnabled
    }

    typealias SyncToggleAction = @MainActor @Sendable (Bool) async -> Void
    typealias CredentialSecretMigrationAction = @MainActor @Sendable (Bool) async throws -> Void
    typealias ChangeSubscriptionAction = @MainActor @Sendable () async -> Void
    typealias ServerReloadAction = @MainActor @Sendable () async -> Void
    typealias TerminalAccessoryRefreshAction = @MainActor @Sendable () async -> Void
    typealias CloudKitStatusRefreshAction = @MainActor @Sendable () async -> Void

    static let shared = AppSyncCoordinator()

    private let applySyncToggle: SyncToggleAction
    private let migrateCredentialSecrets: CredentialSecretMigrationAction
    private let subscribeToChanges: ChangeSubscriptionAction
    private let reloadServerData: ServerReloadAction
    private let refreshTerminalAccessories: TerminalAccessoryRefreshAction
    private let refreshCloudKitStatus: CloudKitStatusRefreshAction

    private var subscriptionTask: Task<Void, Never>?
    private var serverRefreshTask: (id: UUID, task: Task<Void, Never>)?
    private var settingsSyncTask: (id: UUID, task: Task<Bool, Never>)?
    private var cloudKitStatusRefreshTask: (id: UUID, task: Task<Void, Never>)?
    private var remoteNotificationCompletionTasks: [UUID: Task<Bool, Never>] = [:]

    private init(
        applySyncToggle: @escaping SyncToggleAction = { enabled in
            await CloudKitManager.shared.handleSyncToggle(enabled)
        },
        migrateCredentialSecrets: @escaping CredentialSecretMigrationAction = { enabled in
            guard !enabled else { return }
            try KeychainStore(service: "app.vivy.vvterm")
                .migrateAllItems(toICloudSync: false)
            try KeychainStore(service: "app.vivy.vvterm.cloudflare.tokens")
                .migrateAllItems(toICloudSync: false)
        },
        subscribeToChanges: @escaping ChangeSubscriptionAction = {
            await CloudKitManager.shared.subscribeToChanges()
        },
        reloadServerData: @escaping ServerReloadAction = {
            await ServerManager.shared.loadData()
        },
        refreshTerminalAccessories: @escaping TerminalAccessoryRefreshAction = {
            await TerminalAccessoryPreferencesManager.shared.refreshFromCloud()
        },
        refreshCloudKitStatus: @escaping CloudKitStatusRefreshAction = {
            await CloudKitManager.shared.forceSync()
        }
    ) {
        self.applySyncToggle = applySyncToggle
        self.migrateCredentialSecrets = migrateCredentialSecrets
        self.subscribeToChanges = subscribeToChanges
        self.reloadServerData = reloadServerData
        self.refreshTerminalAccessories = refreshTerminalAccessories
        self.refreshCloudKitStatus = refreshCloudKitStatus
    }

    #if DEBUG
    static func makeForTesting(
        applySyncToggle: @escaping SyncToggleAction = { _ in },
        migrateCredentialSecrets: @escaping CredentialSecretMigrationAction = { _ in },
        subscribeToChanges: @escaping ChangeSubscriptionAction = {},
        reloadServerData: @escaping ServerReloadAction = {},
        refreshTerminalAccessories: @escaping TerminalAccessoryRefreshAction = {},
        refreshCloudKitStatus: @escaping CloudKitStatusRefreshAction = {}
    ) -> AppSyncCoordinator {
        AppSyncCoordinator(
            applySyncToggle: applySyncToggle,
            migrateCredentialSecrets: migrateCredentialSecrets,
            subscribeToChanges: subscribeToChanges,
            reloadServerData: reloadServerData,
            refreshTerminalAccessories: refreshTerminalAccessories,
            refreshCloudKitStatus: refreshCloudKitStatus
        )
    }

    var hasPendingCloudKitStatusRefreshForTesting: Bool {
        cloudKitStatusRefreshTask != nil
    }
    #endif

    @discardableResult
    func startChangeSubscription() -> Task<Void, Never> {
        if let subscriptionTask {
            return subscriptionTask
        }

        let task = Task { [subscribeToChanges] in
            await subscribeToChanges()
            subscriptionTask = nil
        }
        subscriptionTask = task
        return task
    }

    @discardableResult
    func refreshServerData(reason: ServerRefreshReason) -> Task<Void, Never> {
        if reason != .settingsEnabled, let serverRefreshTask {
            return serverRefreshTask.task
        }

        let previousRefreshTask = reason == .settingsEnabled ? serverRefreshTask?.task : nil
        let taskID = UUID()
        let task = Task { [reloadServerData] in
            await previousRefreshTask?.value
            guard !Task.isCancelled else {
                clearServerRefreshTask(id: taskID)
                return
            }
            await reloadServerData()
            clearServerRefreshTask(id: taskID)
        }
        serverRefreshTask = (taskID, task)
        return task
    }

    @discardableResult
    func refreshServerDataAfterRemoteNotification(
        onComplete: @escaping @MainActor @Sendable () async -> Void
    ) -> Task<Bool, Never> {
        let refreshTask = refreshServerData(reason: .remoteNotification)
        let completionID = UUID()
        let completionTask = Task {
            defer {
                remoteNotificationCompletionTasks[completionID] = nil
            }
            await refreshTask.value
            guard !Task.isCancelled else { return false }
            await onComplete()
            return true
        }
        remoteNotificationCompletionTasks[completionID] = completionTask
        return completionTask
    }

    @discardableResult
    func handleSyncSettingsChanged(_ enabled: Bool) -> Task<Bool, Never> {
        settingsSyncTask?.task.cancel()
        let taskID = UUID()
        let task = Task { [applySyncToggle, migrateCredentialSecrets, refreshTerminalAccessories] in
            await applySyncToggle(enabled)
            guard !Task.isCancelled else {
                clearSettingsSyncTask(id: taskID)
                return false
            }
            do {
                try await migrateCredentialSecrets(enabled)
            } catch {
                Logger.settings.error("Failed to migrate credential secrets after sync setting change: \(error.localizedDescription)")
                clearSettingsSyncTask(id: taskID)
                return false
            }
            guard !Task.isCancelled else {
                clearSettingsSyncTask(id: taskID)
                return false
            }
            if enabled {
                await refreshServerData(reason: .settingsEnabled).value
                guard !Task.isCancelled else {
                    clearSettingsSyncTask(id: taskID)
                    return false
                }
                await refreshTerminalAccessories()
            }
            clearSettingsSyncTask(id: taskID)
            return true
        }
        settingsSyncTask = (taskID, task)
        return task
    }

    func restoreSyncSettingsAfterFailedChange(_ enabled: Bool) -> Task<Void, Never> {
        Task { [applySyncToggle] in
            await applySyncToggle(enabled)
        }
    }

    @discardableResult
    func refreshCloudKitStatusFromSettings() -> Task<Void, Never> {
        if let cloudKitStatusRefreshTask {
            return cloudKitStatusRefreshTask.task
        }

        let taskID = UUID()
        let task = Task { [refreshCloudKitStatus] in
            await refreshCloudKitStatus()
            clearCloudKitStatusRefreshTask(id: taskID)
        }
        cloudKitStatusRefreshTask = (taskID, task)
        return task
    }

    func cancelAllAndWait() async {
        let tasks =
            [subscriptionTask, serverRefreshTask?.task, cloudKitStatusRefreshTask?.task]
                .compactMap { $0 }
        let settingsTask = settingsSyncTask?.task
        let remoteNotificationTasks = Array(remoteNotificationCompletionTasks.values)

        subscriptionTask?.cancel()
        serverRefreshTask?.task.cancel()
        settingsSyncTask?.task.cancel()
        cloudKitStatusRefreshTask?.task.cancel()
        remoteNotificationCompletionTasks.values.forEach { $0.cancel() }

        subscriptionTask = nil
        serverRefreshTask = nil
        settingsSyncTask = nil
        cloudKitStatusRefreshTask = nil
        remoteNotificationCompletionTasks.removeAll()

        for task in tasks {
            await task.value
        }
        _ = await settingsTask?.value
        for task in remoteNotificationTasks {
            _ = await task.value
        }
    }

    private func clearSettingsSyncTask(id: UUID) {
        guard settingsSyncTask?.id == id else { return }
        settingsSyncTask = nil
    }

    private func clearServerRefreshTask(id: UUID) {
        guard serverRefreshTask?.id == id else { return }
        serverRefreshTask = nil
    }

    private func clearCloudKitStatusRefreshTask(id: UUID) {
        guard cloudKitStatusRefreshTask?.id == id else { return }
        cloudKitStatusRefreshTask = nil
    }
}
