import Foundation
import Testing
@testable import VVTerm

// Test Context:
// These tests protect app-level CloudKit sync trigger ownership. App delegates
// and SwiftUI settings views may send sync intent, but they must not own
// lifecycle-critical sync tasks directly. The fake closures record ordering and
// use an explicit gate so failures distinguish broken task coalescing/completion
// semantics from CloudKit transport behavior. Update this context only when app
// sync trigger ownership intentionally moves to a different application-layer
// coordinator or the sync enable/notification workflow changes.
@Suite(.serialized)
@MainActor
struct AppSyncCoordinatorTests {
    @Test
    func changeSubscriptionLaunchReturnsTrackedSharedTask() async {
        // Given app launch asks the sync coordinator to subscribe to CloudKit changes.
        let probe = AppSyncProbe()
        let releaseSubscription = AsyncGate()
        let coordinator = AppSyncCoordinator.makeForTesting(
            subscribeToChanges: {
                await probe.record("subscribe-start")
                await releaseSubscription.wait()
                await probe.record("subscribe-end")
            }
        )

        // When the launch subscription intent is repeated before completion.
        let first = coordinator.startChangeSubscription()
        let second = coordinator.startChangeSubscription()
        await probe.waitForCount(1)

        // Then both callers can track the same underlying subscription task.
        #expect(await probe.events() == ["subscribe-start"])
        await releaseSubscription.open()
        await first.value
        await second.value
        #expect(
            await probe.events() == ["subscribe-start", "subscribe-end"],
            "Launch subscription intent should expose one tracked task and share duplicate requests."
        )
    }

    @Test
    func concurrentServerRefreshRequestsShareOneTrackedRefreshTask() async {
        // Given app lifecycle events request server refresh while the first
        // refresh is still running.
        let probe = AppSyncProbe()
        let releaseRefresh = AsyncGate()
        let coordinator = AppSyncCoordinator.makeForTesting(
            reloadServerData: {
                await probe.record("reload-start")
                await releaseRefresh.wait()
                await probe.record("reload-end")
            }
        )

        // When two sync intents arrive before the first reload completes.
        let first = coordinator.refreshServerData(reason: .foreground)
        let second = coordinator.refreshServerData(reason: .remoteNotification)
        await probe.waitForCount(1)

        // Then only one application-layer reload is in flight; the second
        // caller waits on the tracked task instead of starting duplicate work.
        #expect(await probe.events() == ["reload-start"])
        await releaseRefresh.open()
        await first.value
        await second.value
        #expect(
            await probe.events() == ["reload-start", "reload-end"],
            "Concurrent app sync refresh intents must share one tracked reload task."
        )
    }

    @Test
    func remoteNotificationCompletionWaitsForTrackedServerRefresh() async {
        // Given remote notification handling starts a server refresh that has
        // not completed yet.
        let probe = AppSyncProbe()
        let releaseRefresh = AsyncGate()
        let coordinator = AppSyncCoordinator.makeForTesting(
            reloadServerData: {
                await probe.record("reload-start")
                await releaseRefresh.wait()
                await probe.record("reload-end")
            }
        )

        // When the notification completion is registered with the coordinator.
        coordinator.refreshServerDataAfterRemoteNotification {
            await probe.record("completion")
        }
        await probe.waitForCount(1)

        // Then the completion handler is not called until the tracked refresh
        // finishes, preserving the system callback contract.
        #expect(await probe.events() == ["reload-start"])
        await releaseRefresh.open()
        await probe.waitForCount(3)
        #expect(
            await probe.events() == ["reload-start", "reload-end", "completion"],
            "Remote notification completion must wait for the tracked sync refresh."
        )
    }

    @Test
    func cloudKitStatusRefreshFromSettingsReusesTrackedTaskUntilCompletion() async {
        // Given settings starts a CloudKit status refresh that has not
        // completed yet.
        let probe = AppSyncProbe()
        let releaseRefresh = AsyncGate()
        let coordinator = AppSyncCoordinator.makeForTesting(
            refreshCloudKitStatus: {
                await probe.record("status-start")
                await releaseRefresh.wait()
                await probe.record("status-end")
            }
        )

        // When the settings screen asks for status refresh twice.
        let first = coordinator.refreshCloudKitStatusFromSettings()
        let second = coordinator.refreshCloudKitStatusFromSettings()
        await probe.waitForCount(1)

        // Then both callers share the same tracked CloudKit refresh task.
        #expect(
            coordinator.hasPendingCloudKitStatusRefreshForTesting,
            "Settings CloudKit status refresh must stay tracked while CloudKit status work is pending."
        )
        #expect(await probe.events() == ["status-start"])

        await releaseRefresh.open()
        await first.value
        await second.value

        #expect(
            await probe.events() == ["status-start", "status-end"],
            "Duplicate settings status refresh intent should share one tracked CloudKit refresh task."
        )
        #expect(
            !coordinator.hasPendingCloudKitStatusRefreshForTesting,
            "AppSyncCoordinator should clear CloudKit status refresh tracking after completion."
        )
    }

    @Test
    func syncSettingsEnableRunsToggleRefreshAndAccessoryRefreshAsTrackedTask() async {
        // Given the settings UI enables iCloud sync.
        let probe = AppSyncProbe()
        let coordinator = AppSyncCoordinator.makeForTesting(
            applySyncToggle: { enabled in
                await probe.record("toggle:\(enabled)")
            },
            reloadServerData: {
                await probe.record("reload")
            },
            refreshTerminalAccessories: {
                await probe.record("accessories")
            }
        )

        // When settings sends enable intent to the application-layer owner.
        let task = coordinator.handleSyncSettingsChanged(true)
        await task.value

        // Then the full settings-triggered sync workflow is owned and ordered
        // by the coordinator instead of ad hoc SwiftUI tasks.
        #expect(
            await probe.events() == ["toggle:true", "reload", "accessories"],
            "Enabling sync from settings must run toggle, server reload, and accessory refresh in order."
        )
    }

    @Test
    func syncSettingsEnableQueuesReloadAfterExistingForegroundRefresh() async {
        // Given a foreground refresh was already running before settings
        // enabled iCloud sync.
        let probe = AppSyncProbe()
        let releaseForegroundRefresh = AsyncGate()
        let coordinator = AppSyncCoordinator.makeForTesting(
            applySyncToggle: { enabled in
                await probe.record("toggle:\(enabled)")
            },
            reloadServerData: {
                await probe.record("reload-start")
                await releaseForegroundRefresh.wait()
                await probe.record("reload-end")
            },
            refreshTerminalAccessories: {
                await probe.record("accessories")
            }
        )

        // When settings enable intent arrives while the old foreground refresh
        // is still in flight.
        let foregroundTask = coordinator.refreshServerData(reason: .foreground)
        await probe.waitForCount(1)
        let settingsTask = coordinator.handleSyncSettingsChanged(true)
        await probe.waitForCount(2)
        await releaseForegroundRefresh.open()
        await foregroundTask.value
        await settingsTask.value

        // Then settings enable performs its own post-toggle server reload
        // before accessory refresh instead of treating the earlier foreground
        // refresh as satisfying the settings workflow.
        #expect(
            await probe.events() == [
                "reload-start",
                "toggle:true",
                "reload-end",
                "reload-start",
                "reload-end",
                "accessories"
            ],
            "Settings enable must queue a reload after toggle even when another refresh is already in flight."
        )
    }

    @Test
    func syncSettingsDisableCancelsInFlightEnableIntent() async throws {
        // Given enabling iCloud sync is still waiting on CloudKit/account work.
        let probe = AppSyncProbe()
        let releaseEnable = AsyncGate()
        let coordinator = AppSyncCoordinator.makeForTesting(
            applySyncToggle: { enabled in
                await probe.record("toggle:\(enabled)")
                if enabled {
                    await releaseEnable.wait()
                }
            },
            reloadServerData: {
                await probe.record("reload")
            },
            refreshTerminalAccessories: {
                await probe.record("accessories")
            }
        )

        // When settings immediately sends a disable intent.
        let enableTask = coordinator.handleSyncSettingsChanged(true)
        await probe.waitForCount(1)
        let disableTask = coordinator.handleSyncSettingsChanged(false)
        try await Task.sleep(for: .milliseconds(20))

        // Then the disable intent is not swallowed by the in-flight enable
        // task, and the canceled enable workflow does not continue into refresh
        // work after CloudKit/account work unblocks.
        #expect(
            await probe.events() == ["toggle:true", "toggle:false"],
            "A later settings disable intent must start its own tracked task instead of reusing the in-flight enable task."
        )
        await releaseEnable.open()
        await enableTask.value
        await disableTask.value
        #expect(
            await probe.events() == ["toggle:true", "toggle:false"],
            "Canceled enable intent must not run server/accessory refresh after disable intent wins."
        )
    }

    @Test
    func cancelAllAndWaitCancelsRemoteNotificationCompletionButWaitsForRefreshExit() async throws {
        // Given remote notification sync is waiting on a tracked server refresh.
        let probe = AppSyncProbe()
        let releaseRefresh = AsyncGate()
        let coordinator = AppSyncCoordinator.makeForTesting(
            reloadServerData: {
                await probe.record("reload-start")
                await releaseRefresh.wait()
                await probe.record("reload-end")
            }
        )

        coordinator.refreshServerDataAfterRemoteNotification {
            await probe.record("completion")
        }
        await probe.waitForCount(1)

        // When app-level teardown cancels sync while refresh work is still
        // blocked inside the Application owner.
        let cleanupTask = Task {
            await coordinator.cancelAllAndWait()
            await probe.record("cleanup-end")
        }
        try await Task.sleep(for: .milliseconds(20))

        // Then cleanup remains awaitable until the underlying refresh exits.
        #expect(await probe.events() == ["reload-start"])

        await releaseRefresh.open()
        await cleanupTask.value

        #expect(
            await probe.events() == ["reload-start", "reload-end", "cleanup-end"],
            "Sync cleanup should wait for refresh exit and suppress canceled remote-notification completion."
        )
    }

    @Test
    func canceledRemoteNotificationRefreshTaskCompletesFalseWithoutCallingCompletion() async throws {
        // Given a remote-notification completion task is waiting on a tracked
        // server refresh.
        let probe = AppSyncProbe()
        let releaseRefresh = AsyncGate()
        let coordinator = AppSyncCoordinator.makeForTesting(
            reloadServerData: {
                await probe.record("reload-start")
                await releaseRefresh.wait()
                await probe.record("reload-end")
            }
        )

        let notificationTask = coordinator.refreshServerDataAfterRemoteNotification {
            await probe.record("completion")
        }
        await probe.waitForCount(1)

        // When app-level sync cleanup cancels remote notification completion.
        let cleanupTask = Task {
            await coordinator.cancelAllAndWait()
            await probe.record("cleanup-end")
        }
        try await Task.sleep(for: .milliseconds(20))
        await releaseRefresh.open()
        await cleanupTask.value
        let didComplete = await notificationTask.value

        // Then the returned task still completes so app lifecycle callers do
        // not hang, but the system completion callback remains suppressed.
        #expect(!didComplete, "Canceled remote notification refresh task should complete with false.")
        #expect(
            await probe.events() == ["reload-start", "reload-end", "cleanup-end"],
            "Canceled remote notification refresh should not call completion after sync teardown wins."
        )
    }

    @Test
    func cancelAllAndWaitAwaitsEveryTrackedSyncTask() async throws {
        let probe = AppSyncProbe()
        let releaseSubscription = AsyncGate()
        let releaseSettings = AsyncGate()
        let releaseStatus = AsyncGate()
        let coordinator = AppSyncCoordinator.makeForTesting(
            applySyncToggle: { enabled in
                await probe.record("settings-start:\(enabled)")
                await releaseSettings.wait()
                await probe.record("settings-end:\(enabled)")
            },
            subscribeToChanges: {
                await probe.record("subscription-start")
                await releaseSubscription.wait()
                await probe.record("subscription-end")
            },
            refreshCloudKitStatus: {
                await probe.record("status-start")
                await releaseStatus.wait()
                await probe.record("status-end")
            }
        )

        // Given several app-owned sync tasks are in flight.
        _ = coordinator.startChangeSubscription()
        _ = coordinator.handleSyncSettingsChanged(false)
        _ = coordinator.refreshCloudKitStatusFromSettings()
        await probe.waitForCount(3)

        // When app-level teardown requests sync cleanup.
        let cleanupTask = Task {
            await coordinator.cancelAllAndWait()
            await probe.record("cleanup-end")
        }
        try await Task.sleep(for: .milliseconds(20))

        // Then cleanup remains pending until all tracked sync tasks exit.
        #expect(
            await probe.events() == ["subscription-start", "settings-start:false", "status-start"]
        )

        await releaseSubscription.open()
        try await Task.sleep(for: .milliseconds(20))
        #expect(!(await probe.events()).contains("cleanup-end"))

        await releaseSettings.open()
        try await Task.sleep(for: .milliseconds(20))
        #expect(!(await probe.events()).contains("cleanup-end"))

        await releaseStatus.open()
        await cleanupTask.value

        #expect(
            await probe.events() == [
                "subscription-start",
                "settings-start:false",
                "status-start",
                "subscription-end",
                "settings-end:false",
                "status-end",
                "cleanup-end"
            ],
            "Sync cleanup should wait for every tracked sync task before reporting completion."
        )
    }
}

private actor AppSyncProbe {
    private var recordedEvents: [String] = []
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func record(_ event: String) {
        recordedEvents.append(event)
        resumeReadyContinuations()
    }

    func events() -> [String] {
        recordedEvents
    }

    func waitForCount(_ count: Int) async {
        if recordedEvents.count >= count { return }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
        if recordedEvents.count < count {
            await waitForCount(count)
        }
    }

    private func resumeReadyContinuations() {
        let ready = continuations
        continuations.removeAll()
        for continuation in ready {
            continuation.resume()
        }
    }
}

private actor AsyncGate {
    private var isOpen = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func open() {
        isOpen = true
        let ready = continuations
        continuations.removeAll()
        for continuation in ready {
            continuation.resume()
        }
    }

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }
}
