import Foundation

@MainActor
final class AppSyncCoordinator {
    enum ServerRefreshReason {
        case foreground
        case remoteNotification
        case settingsEnabled
    }

    typealias SyncToggleAction = @MainActor @Sendable (Bool) async -> Void
    typealias ChangeSubscriptionAction = @MainActor @Sendable () async -> Void
    typealias ServerReloadAction = @MainActor @Sendable () async -> Void
    typealias TerminalAccessoryRefreshAction = @MainActor @Sendable () async -> Void
    typealias CloudKitStatusRefreshAction = @MainActor @Sendable () async -> Void

    static let shared = AppSyncCoordinator()

    private let applySyncToggle: SyncToggleAction
    private let subscribeToChanges: ChangeSubscriptionAction
    private let reloadServerData: ServerReloadAction
    private let refreshTerminalAccessories: TerminalAccessoryRefreshAction
    private let refreshCloudKitStatus: CloudKitStatusRefreshAction

    private var subscriptionTask: Task<Void, Never>?
    private var serverRefreshTask: (id: UUID, task: Task<Void, Never>)?
    private var settingsSyncTask: (id: UUID, task: Task<Void, Never>)?
    private var cloudKitStatusRefreshTask: Task<Void, Never>?
    private var remoteNotificationCompletionTasks: [UUID: Task<Void, Never>] = [:]

    private init(
        applySyncToggle: @escaping SyncToggleAction = { enabled in
            await CloudKitManager.shared.handleSyncToggle(enabled)
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
        self.subscribeToChanges = subscribeToChanges
        self.reloadServerData = reloadServerData
        self.refreshTerminalAccessories = refreshTerminalAccessories
        self.refreshCloudKitStatus = refreshCloudKitStatus
    }

    #if DEBUG
    static func makeForTesting(
        applySyncToggle: @escaping SyncToggleAction = { _ in },
        subscribeToChanges: @escaping ChangeSubscriptionAction = {},
        reloadServerData: @escaping ServerReloadAction = {},
        refreshTerminalAccessories: @escaping TerminalAccessoryRefreshAction = {},
        refreshCloudKitStatus: @escaping CloudKitStatusRefreshAction = {}
    ) -> AppSyncCoordinator {
        AppSyncCoordinator(
            applySyncToggle: applySyncToggle,
            subscribeToChanges: subscribeToChanges,
            reloadServerData: reloadServerData,
            refreshTerminalAccessories: refreshTerminalAccessories,
            refreshCloudKitStatus: refreshCloudKitStatus
        )
    }
    #endif

    func startChangeSubscription() {
        guard subscriptionTask == nil else { return }

        subscriptionTask = Task { [subscribeToChanges] in
            await subscribeToChanges()
            subscriptionTask = nil
        }
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

    func refreshServerDataAfterRemoteNotification(onComplete: @escaping @MainActor @Sendable () async -> Void) {
        let refreshTask = refreshServerData(reason: .remoteNotification)
        let completionID = UUID()
        let completionTask = Task {
            await refreshTask.value
            await onComplete()
            remoteNotificationCompletionTasks[completionID] = nil
        }
        remoteNotificationCompletionTasks[completionID] = completionTask
    }

    @discardableResult
    func handleSyncSettingsChanged(_ enabled: Bool) -> Task<Void, Never> {
        settingsSyncTask?.task.cancel()
        let taskID = UUID()
        let task = Task { [applySyncToggle, refreshTerminalAccessories] in
            await applySyncToggle(enabled)
            guard !Task.isCancelled else {
                clearSettingsSyncTask(id: taskID)
                return
            }
            if enabled {
                await refreshServerData(reason: .settingsEnabled).value
                guard !Task.isCancelled else {
                    clearSettingsSyncTask(id: taskID)
                    return
                }
                await refreshTerminalAccessories()
            }
            clearSettingsSyncTask(id: taskID)
        }
        settingsSyncTask = (taskID, task)
        return task
    }

    @discardableResult
    func refreshCloudKitStatusFromSettings() -> Task<Void, Never> {
        if let cloudKitStatusRefreshTask {
            return cloudKitStatusRefreshTask
        }

        let task = Task { [refreshCloudKitStatus] in
            await refreshCloudKitStatus()
            cloudKitStatusRefreshTask = nil
        }
        cloudKitStatusRefreshTask = task
        return task
    }

    private func clearSettingsSyncTask(id: UUID) {
        guard settingsSyncTask?.id == id else { return }
        settingsSyncTask = nil
    }

    private func clearServerRefreshTask(id: UUID) {
        guard serverRefreshTask?.id == id else { return }
        serverRefreshTask = nil
    }
}
