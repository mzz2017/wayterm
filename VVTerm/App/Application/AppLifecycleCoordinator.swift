import Foundation

@MainActor
final class AppLifecycleCoordinator {
    typealias TerminalLifecycleAction = @MainActor @Sendable () async -> Void
    typealias AppLockLifecycleAction = @MainActor @Sendable () async -> Void
    typealias LaunchAction = @MainActor @Sendable () -> Task<Void, Never>
    typealias ServerRefreshAction = @MainActor @Sendable (AppSyncCoordinator.ServerRefreshReason) -> Task<Void, Never>
    typealias RemoteNotificationRefreshAction = @MainActor @Sendable () async -> Bool
    typealias RemoteNotificationCompletionAction = @MainActor @Sendable (Bool) async -> Void
    typealias SyncEnabledProvider = @MainActor @Sendable () -> Bool
    typealias DateProvider = @MainActor @Sendable () -> Date
    typealias LanguageChangeAction = @MainActor @Sendable (String) -> Void
    typealias SleepAction = @Sendable (Duration) async -> Void

    static let shared = AppLifecycleCoordinator()

    fileprivate enum TerminationTeardownResult {
        case completed
        case timedOut
    }

    private let disconnectConnectionSessionsBeforeExit: TerminalLifecycleAction
    private let disconnectTerminalTabsBeforeExit: TerminalLifecycleAction
    private var disconnectRemoteFilesBeforeExit: TerminalLifecycleAction
    private var disconnectStatsBeforeExit: TerminalLifecycleAction
    private let cancelAuthBeforeExit: TerminalLifecycleAction
    private let cancelSyncBeforeExit: TerminalLifecycleAction
    private let cancelStoreBeforeExit: TerminalLifecycleAction
    private let cancelVoiceModelDownloadsBeforeExit: TerminalLifecycleAction
    private let suspendTerminalSessionsForBackground: TerminalLifecycleAction
    private let lockAppIfNeededForBackground: AppLockLifecycleAction
    private let startChangeSubscription: LaunchAction
    private let refreshServerData: ServerRefreshAction
    private let refreshServerDataAfterRemoteNotification: RemoteNotificationRefreshAction
    private let isSyncEnabled: SyncEnabledProvider
    private let now: DateProvider
    private let handleAppLanguageChangeAction: LanguageChangeAction
    private let foregroundSyncMinimumInterval: TimeInterval
    private let terminationTeardownTimeout: Duration
    private let sleepForTerminationTimeout: SleepAction

    private var lastForegroundSyncAt: Date = .distantPast
    private var backgroundLockRequestTasks: [UUID: Task<Void, Never>] = [:]
    private var backgroundSuspensionRequestTasks: [UUID: Task<Void, Never>] = [:]
    private var remoteNotificationRefreshRequestTasks: [UUID: Task<Void, Never>] = [:]
    private var terminationTeardownRequestTasks: [UUID: Task<Void, Never>] = [:]

    var pendingBackgroundLockRequestIDs: Set<UUID> {
        Set(backgroundLockRequestTasks.keys)
    }

    var pendingBackgroundSuspensionRequestIDs: Set<UUID> {
        Set(backgroundSuspensionRequestTasks.keys)
    }

    var pendingRemoteNotificationRefreshRequestIDs: Set<UUID> {
        Set(remoteNotificationRefreshRequestTasks.keys)
    }

    var pendingTerminationTeardownRequestIDs: Set<UUID> {
        Set(terminationTeardownRequestTasks.keys)
    }

    private init(
        disconnectConnectionSessionsBeforeExit: @escaping TerminalLifecycleAction = {
            await ConnectionSessionManager.shared.disconnectAllAndWait()
        },
        disconnectTerminalTabsBeforeExit: @escaping TerminalLifecycleAction = {
            await TerminalTabManager.shared.disconnectAllAndWait()
        },
        disconnectRemoteFilesBeforeExit: @escaping TerminalLifecycleAction = {},
        disconnectStatsBeforeExit: @escaping TerminalLifecycleAction = {},
        cancelAuthBeforeExit: @escaping TerminalLifecycleAction = {
            await AppLockManager.shared.cancelAllAndWait()
        },
        cancelSyncBeforeExit: @escaping TerminalLifecycleAction = {
            await AppSyncCoordinator.shared.cancelAllAndWait()
        },
        cancelStoreBeforeExit: @escaping TerminalLifecycleAction = {
            await StoreManager.shared.cancelAllAndWait()
        },
        cancelVoiceModelDownloadsBeforeExit: @escaping TerminalLifecycleAction = {
            await VoiceModelDownloadStore.shared.cancelAllAndWait()
        },
        suspendTerminalSessionsForBackground: @escaping TerminalLifecycleAction = {
            await ConnectionSessionManager.shared.suspendAllForBackground()
        },
        lockAppIfNeededForBackground: @escaping AppLockLifecycleAction = {
            AppLockManager.shared.lockIfNeededForBackground()
        },
        startChangeSubscription: @escaping LaunchAction = {
            AppSyncCoordinator.shared.startChangeSubscription()
        },
        refreshServerData: @escaping ServerRefreshAction = { reason in
            AppSyncCoordinator.shared.refreshServerData(reason: reason)
        },
        refreshServerDataAfterRemoteNotification: @escaping RemoteNotificationRefreshAction = {
            guard SyncSettings.isEnabled else {
                return false
            }

            return await withCheckedContinuation { continuation in
                AppSyncCoordinator.shared.refreshServerDataAfterRemoteNotification {
                    continuation.resume(returning: true)
                }
            }
        },
        isSyncEnabled: @escaping SyncEnabledProvider = {
            SyncSettings.isEnabled
        },
        now: @escaping DateProvider = {
            Date()
        },
        handleAppLanguageChange: @escaping LanguageChangeAction = { _ in
            ServerManager.shared.handleAppLanguageChange()
        },
        foregroundSyncMinimumInterval: TimeInterval = 20,
        terminationTeardownTimeout: Duration = .seconds(2),
        sleepForTerminationTimeout: @escaping SleepAction = { duration in
            try? await Task.sleep(for: duration)
        }
    ) {
        self.disconnectConnectionSessionsBeforeExit = disconnectConnectionSessionsBeforeExit
        self.disconnectTerminalTabsBeforeExit = disconnectTerminalTabsBeforeExit
        self.disconnectRemoteFilesBeforeExit = disconnectRemoteFilesBeforeExit
        self.disconnectStatsBeforeExit = disconnectStatsBeforeExit
        self.cancelAuthBeforeExit = cancelAuthBeforeExit
        self.cancelSyncBeforeExit = cancelSyncBeforeExit
        self.cancelStoreBeforeExit = cancelStoreBeforeExit
        self.cancelVoiceModelDownloadsBeforeExit = cancelVoiceModelDownloadsBeforeExit
        self.suspendTerminalSessionsForBackground = suspendTerminalSessionsForBackground
        self.lockAppIfNeededForBackground = lockAppIfNeededForBackground
        self.startChangeSubscription = startChangeSubscription
        self.refreshServerData = refreshServerData
        self.refreshServerDataAfterRemoteNotification = refreshServerDataAfterRemoteNotification
        self.isSyncEnabled = isSyncEnabled
        self.now = now
        self.handleAppLanguageChangeAction = handleAppLanguageChange
        self.foregroundSyncMinimumInterval = foregroundSyncMinimumInterval
        self.terminationTeardownTimeout = terminationTeardownTimeout
        self.sleepForTerminationTimeout = sleepForTerminationTimeout
    }

    #if DEBUG
    static func makeForTesting(
        disconnectConnectionSessionsBeforeExit: @escaping TerminalLifecycleAction = {},
        disconnectTerminalTabsBeforeExit: @escaping TerminalLifecycleAction = {},
        disconnectRemoteFilesBeforeExit: @escaping TerminalLifecycleAction = {},
        disconnectStatsBeforeExit: @escaping TerminalLifecycleAction = {},
        cancelAuthBeforeExit: @escaping TerminalLifecycleAction = {},
        cancelSyncBeforeExit: @escaping TerminalLifecycleAction = {},
        cancelStoreBeforeExit: @escaping TerminalLifecycleAction = {},
        cancelVoiceModelDownloadsBeforeExit: @escaping TerminalLifecycleAction = {},
        suspendTerminalSessionsForBackground: @escaping TerminalLifecycleAction = {},
        lockAppIfNeededForBackground: @escaping AppLockLifecycleAction = {},
        startChangeSubscription: @escaping LaunchAction = { Task {} },
        refreshServerData: @escaping ServerRefreshAction = { _ in Task {} },
        refreshServerDataAfterRemoteNotification: @escaping RemoteNotificationRefreshAction = { true },
        isSyncEnabled: @escaping SyncEnabledProvider = { true },
        now: @escaping DateProvider = { Date() },
        handleAppLanguageChange: @escaping LanguageChangeAction = { _ in },
        foregroundSyncMinimumInterval: TimeInterval = 20,
        terminationTeardownTimeout: Duration = .seconds(2),
        sleepForTerminationTimeout: @escaping SleepAction = { duration in
            try? await Task.sleep(for: duration)
        }
    ) -> AppLifecycleCoordinator {
        AppLifecycleCoordinator(
            disconnectConnectionSessionsBeforeExit: disconnectConnectionSessionsBeforeExit,
            disconnectTerminalTabsBeforeExit: disconnectTerminalTabsBeforeExit,
            disconnectRemoteFilesBeforeExit: disconnectRemoteFilesBeforeExit,
            disconnectStatsBeforeExit: disconnectStatsBeforeExit,
            cancelAuthBeforeExit: cancelAuthBeforeExit,
            cancelSyncBeforeExit: cancelSyncBeforeExit,
            cancelStoreBeforeExit: cancelStoreBeforeExit,
            cancelVoiceModelDownloadsBeforeExit: cancelVoiceModelDownloadsBeforeExit,
            suspendTerminalSessionsForBackground: suspendTerminalSessionsForBackground,
            lockAppIfNeededForBackground: lockAppIfNeededForBackground,
            startChangeSubscription: startChangeSubscription,
            refreshServerData: refreshServerData,
            refreshServerDataAfterRemoteNotification: refreshServerDataAfterRemoteNotification,
            isSyncEnabled: isSyncEnabled,
            now: now,
            handleAppLanguageChange: handleAppLanguageChange,
            foregroundSyncMinimumInterval: foregroundSyncMinimumInterval,
            terminationTeardownTimeout: terminationTeardownTimeout,
            sleepForTerminationTimeout: sleepForTerminationTimeout
        )
    }
    #endif

    @discardableResult
    func requestLaunch() -> Task<Void, Never> {
        startChangeSubscription()
    }

    func requestForegroundRefresh() {
        guard isSyncEnabled() else { return }

        let currentDate = now()
        guard currentDate.timeIntervalSince(lastForegroundSyncAt) >= foregroundSyncMinimumInterval else {
            return
        }
        lastForegroundSyncAt = currentDate

        _ = refreshServerData(.foreground)
    }

    @discardableResult
    func requestRemoteNotificationRefresh(
        onComplete: @escaping RemoteNotificationCompletionAction = { _ in }
    ) -> UUID {
        let requestID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                remoteNotificationRefreshRequestTasks.removeValue(forKey: requestID)
            }

            let didRefresh = await refreshServerDataAfterRemoteNotification()
            guard !Task.isCancelled else { return }
            await onComplete(didRefresh)
        }
        remoteNotificationRefreshRequestTasks[requestID] = task
        return requestID
    }

    @discardableResult
    func requestBackgroundLock() -> UUID {
        let requestID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                backgroundLockRequestTasks.removeValue(forKey: requestID)
            }

            await lockAppIfNeededForBackground()
        }
        backgroundLockRequestTasks[requestID] = task
        return requestID
    }

    @discardableResult
    func requestBackgroundSuspension() -> UUID {
        let requestID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                backgroundSuspensionRequestTasks.removeValue(forKey: requestID)
            }

            await suspendTerminalSessionsForBackground()
            guard !Task.isCancelled else { return }
            await lockAppIfNeededForBackground()
        }
        backgroundSuspensionRequestTasks[requestID] = task
        return requestID
    }

    func waitForBackgroundSuspensionRequest(_ requestID: UUID) async {
        await backgroundSuspensionRequestTasks[requestID]?.value
    }

    func waitForBackgroundLockRequest(_ requestID: UUID) async {
        await backgroundLockRequestTasks[requestID]?.value
    }

    func waitForRemoteNotificationRefreshRequest(_ requestID: UUID) async {
        await remoteNotificationRefreshRequestTasks[requestID]?.value
    }

    @discardableResult
    func requestTerminationTeardown(onCompleted: (@MainActor @Sendable () -> Void)? = nil) -> UUID {
        let requestID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                terminationTeardownRequestTasks.removeValue(forKey: requestID)
            }

            await runTerminationTeardownOrTimeout()
            onCompleted?()
        }
        terminationTeardownRequestTasks[requestID] = task
        return requestID
    }

    func waitForTerminationTeardownRequest(_ requestID: UUID) async {
        await terminationTeardownRequestTasks[requestID]?.value
    }

    func handleAppLanguageChange(_ appLanguage: String) {
        handleAppLanguageChangeAction(appLanguage)
    }

    func configureTerminationTeardown(
        disconnectRemoteFilesBeforeExit: @escaping TerminalLifecycleAction,
        disconnectStatsBeforeExit: @escaping TerminalLifecycleAction
    ) {
        self.disconnectRemoteFilesBeforeExit = disconnectRemoteFilesBeforeExit
        self.disconnectStatsBeforeExit = disconnectStatsBeforeExit
    }

    private func runTerminationTeardownOrTimeout() async {
        let cancelAuthBeforeExit = cancelAuthBeforeExit
        let cancelSyncBeforeExit = cancelSyncBeforeExit
        let cancelStoreBeforeExit = cancelStoreBeforeExit
        let cancelVoiceModelDownloadsBeforeExit = cancelVoiceModelDownloadsBeforeExit
        let disconnectRemoteFilesBeforeExit = disconnectRemoteFilesBeforeExit
        let disconnectStatsBeforeExit = disconnectStatsBeforeExit
        let disconnectConnectionSessionsBeforeExit = disconnectConnectionSessionsBeforeExit
        let disconnectTerminalTabsBeforeExit = disconnectTerminalTabsBeforeExit
        let sleepForTerminationTimeout = sleepForTerminationTimeout
        let terminationTeardownTimeout = terminationTeardownTimeout
        let teardownTask = Task { @MainActor in
            await cancelAuthBeforeExit()
            guard !Task.isCancelled else { return }
            await cancelSyncBeforeExit()
            guard !Task.isCancelled else { return }
            await cancelStoreBeforeExit()
            guard !Task.isCancelled else { return }
            await cancelVoiceModelDownloadsBeforeExit()
            guard !Task.isCancelled else { return }
            await disconnectRemoteFilesBeforeExit()
            guard !Task.isCancelled else { return }
            await disconnectStatsBeforeExit()
            guard !Task.isCancelled else { return }
            await disconnectConnectionSessionsBeforeExit()
            guard !Task.isCancelled else { return }
            await disconnectTerminalTabsBeforeExit()
        }
        let timeoutTask = Task {
            await sleepForTerminationTimeout(terminationTeardownTimeout)
        }

        let race = AppLifecycleTerminationTeardownRace()
        let teardownWaiter = Task {
            await teardownTask.value
            await race.finish(.completed)
        }
        let timeoutWaiter = Task {
            await timeoutTask.value
            await race.finish(.timedOut)
        }

        _ = await race.wait()
        teardownTask.cancel()
        timeoutTask.cancel()
        teardownWaiter.cancel()
        timeoutWaiter.cancel()
    }
}

private actor AppLifecycleTerminationTeardownRace {
    private var result: AppLifecycleCoordinator.TerminationTeardownResult?
    private var continuation: CheckedContinuation<AppLifecycleCoordinator.TerminationTeardownResult, Never>?

    func finish(_ result: AppLifecycleCoordinator.TerminationTeardownResult) {
        guard self.result == nil else { return }

        self.result = result
        continuation?.resume(returning: result)
        continuation = nil
    }

    func wait() async -> AppLifecycleCoordinator.TerminationTeardownResult {
        if let result {
            return result
        }

        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }
}
