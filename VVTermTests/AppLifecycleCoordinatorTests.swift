import Foundation
import Testing
@testable import VVTerm

// Test Context:
// These tests protect app delegate and root app lifecycle ownership. Platform
// delegates may send launch, foreground, remote-notification, background, and
// termination intent, but they must not own lifecycle-critical terminal
// teardown, background suspension, app-lock, or sync task orchestration. The
// fake closures record ordering and use gates so failures distinguish broken
// application-layer lifecycle ownership from CloudKit, UIKit, AppKit, or real
// terminal manager behavior. Update this context only when app lifecycle
// orchestration intentionally moves to another App/Application owner.
@Suite(.serialized)
@MainActor
struct AppLifecycleCoordinatorTests {
    @Test
    func launchRequestReturnsTrackedSubscriptionTask() async {
        // Given app launch delegates subscription setup to the lifecycle coordinator.
        let probe = AppLifecycleProbe()
        let releaseSubscription = AsyncLifecycleGate()
        let coordinator = AppLifecycleCoordinator.makeForTesting(
            startChangeSubscription: {
                Task {
                    await probe.record("subscription-start")
                    await releaseSubscription.wait()
                    await probe.record("subscription-end")
                }
            }
        )

        // When launch is requested.
        let task = coordinator.requestLaunch()
        await probe.waitForCount(1)

        // Then the caller can wait for subscription setup to finish.
        #expect(await probe.events() == ["subscription-start"])
        await releaseSubscription.open()
        await task.value
        #expect(
            await probe.events() == ["subscription-start", "subscription-end"],
            "Launch lifecycle intent should return the tracked sync subscription task."
        )
    }

    @Test
    func backgroundLockRequestTracksLockUntilCompletion() async {
        // Given app background lock work is asynchronous at the application
        // lifecycle boundary.
        let probe = AppLifecycleProbe()
        let releaseLock = AsyncLifecycleGate()
        let coordinator = AppLifecycleCoordinator.makeForTesting(
            lockAppIfNeededForBackground: {
                await probe.record("lock-start")
                await releaseLock.wait()
                await probe.record("lock-end")
            }
        )

        // When the platform delegate sends background-lock intent.
        let requestID = coordinator.requestBackgroundLock()
        await probe.waitForCount(1)

        // Then the application owner tracks the lock request until the work
        // finishes.
        #expect(
            coordinator.pendingBackgroundLockRequestIDs.contains(requestID),
            "Background lock should stay tracked while app-lock work is in flight."
        )
        #expect(await probe.events() == ["lock-start"])

        await releaseLock.open()
        await coordinator.waitForBackgroundLockRequest(requestID)

        #expect(
            await probe.events() == ["lock-start", "lock-end"],
            "Background lock request should wait for app-lock work to finish."
        )
        #expect(
            !coordinator.pendingBackgroundLockRequestIDs.contains(requestID),
            "Background lock tracking should clear only after app-lock work completes."
        )
    }

    @Test
    func backgroundSuspensionRequestTracksSuspendUntilLockCompletes() async {
        // Given app background suspension is blocked inside the terminal
        // session manager boundary.
        let probe = AppLifecycleProbe()
        let releaseSuspend = AsyncLifecycleGate()
        let coordinator = AppLifecycleCoordinator.makeForTesting(
            suspendTerminalSessionsForBackground: {
                await probe.record("suspend-start")
                await releaseSuspend.wait()
                await probe.record("suspend-end")
            },
            lockAppIfNeededForBackground: {
                await probe.record("lock")
            }
        )

        // When the platform delegate sends background intent.
        let requestID = coordinator.requestBackgroundSuspension()
        await probe.waitForCount(1)

        // Then the application-layer owner tracks the request until suspend
        // finishes and lock intent has been sent.
        #expect(
            coordinator.pendingBackgroundSuspensionRequestIDs.contains(requestID),
            "Background suspension should stay tracked while terminal suspension is in flight."
        )
        #expect(await probe.events() == ["suspend-start"])

        await releaseSuspend.open()
        await coordinator.waitForBackgroundSuspensionRequest(requestID)

        #expect(
            await probe.events() == ["suspend-start", "suspend-end", "lock"],
            "App lock should run after terminal suspension completes."
        )
        #expect(
            !coordinator.pendingBackgroundSuspensionRequestIDs.contains(requestID),
            "Background suspension tracking should clear only after the lifecycle work completes."
        )
    }

    @Test
    func backgroundSuspensionHoldsBackgroundLeaseUntilSuspendAndLockComplete() async {
        // Given iOS grants a finite background execution lease while the app
        // suspends terminal resources.
        let probe = AppLifecycleProbe()
        let backgroundLeaser = RecordingAppBackgroundTaskLeaser()
        let releaseSuspend = AsyncLifecycleGate()
        let coordinator = AppLifecycleCoordinator.makeForTesting(
            suspendTerminalSessionsForBackground: {
                await probe.record("suspend-start")
                await releaseSuspend.wait()
                await probe.record("suspend-end")
            },
            lockAppIfNeededForBackground: {
                await probe.record("lock")
            },
            backgroundTaskLeaser: backgroundLeaser
        )

        // When the platform delegate sends background intent.
        let requestID = coordinator.requestBackgroundSuspension()
        await probe.waitForCount(1)

        // Then the application lifecycle owner has acquired a background lease
        // before async suspension work is allowed to remain pending.
        #expect(backgroundLeaser.events == ["begin:background-suspension"])
        #expect(backgroundLeaser.activeLeaseCount == 1)

        await releaseSuspend.open()
        await coordinator.waitForBackgroundSuspensionRequest(requestID)

        // And the lease is ended only after suspension and app lock complete.
        #expect(await probe.events() == ["suspend-start", "suspend-end", "lock"])
        #expect(backgroundLeaser.events == ["begin:background-suspension", "end:background-suspension"])
        #expect(backgroundLeaser.activeLeaseCount == 0)
    }

    @Test
    func terminationTeardownRequestTracksBothTerminalManagersUntilCompletion() async {
        // Given terminal teardown dependencies are injected into the app
        // lifecycle owner.
        let probe = AppLifecycleProbe()
        let coordinator = AppLifecycleCoordinator.makeForTesting(
            disconnectConnectionSessionsBeforeExit: {
                await probe.record("sessions")
            },
            disconnectTerminalTabsBeforeExit: {
                await probe.record("tabs")
            }
        )

        // When the platform delegate sends termination intent.
        let requestID = coordinator.requestTerminationTeardown()
        await coordinator.waitForTerminationTeardownRequest(requestID)

        // Then both awaitable terminal teardown paths complete before the
        // tracked termination request clears.
        #expect(
            await probe.events() == ["sessions", "tabs"],
            "Termination should run both terminal manager teardown paths before completing the request."
        )
        #expect(
            !coordinator.pendingTerminationTeardownRequestIDs.contains(requestID),
            "Termination teardown tracking should clear only after both managers finish."
        )
    }

    @Test
    func terminationTeardownRequestStopsStatsBeforeTerminalManagers() async {
        // Given Stats and terminal teardown dependencies are injected into the
        // app lifecycle owner.
        let probe = AppLifecycleProbe()
        let coordinator = AppLifecycleCoordinator.makeForTesting(
            disconnectConnectionSessionsBeforeExit: {
                await probe.record("sessions")
            },
            disconnectTerminalTabsBeforeExit: {
                await probe.record("tabs")
            },
            disconnectStatsBeforeExit: {
                await probe.record("stats")
            }
        )

        // When the platform delegate sends termination intent.
        let requestID = coordinator.requestTerminationTeardown()
        await coordinator.waitForTerminationTeardownRequest(requestID)

        // Then Stats collection stops before terminal managers close shared
        // terminal leases.
        #expect(
            await probe.events() == ["stats", "sessions", "tabs"],
            "Termination should stop Stats collection before terminal managers close shared terminal leases."
        )
    }

    @Test
    func terminationTeardownRequestStopsRemoteFilesBeforeStatsAndTerminalManagers() async {
        // Given RemoteFiles, Stats, and terminal teardown dependencies are
        // injected into the app lifecycle owner.
        let probe = AppLifecycleProbe()
        let coordinator = AppLifecycleCoordinator.makeForTesting(
            disconnectConnectionSessionsBeforeExit: {
                await probe.record("sessions")
            },
            disconnectTerminalTabsBeforeExit: {
                await probe.record("tabs")
            },
            disconnectRemoteFilesBeforeExit: {
                await probe.record("remote-files")
            },
            disconnectStatsBeforeExit: {
                await probe.record("stats")
            }
        )

        // When the platform delegate sends termination intent.
        let requestID = coordinator.requestTerminationTeardown()
        await coordinator.waitForTerminationTeardownRequest(requestID)

        // Then file transfers/SFTP leases stop before Stats and terminal
        // managers close shared terminal leases.
        #expect(
            await probe.events() == ["remote-files", "stats", "sessions", "tabs"],
            "Termination should stop RemoteFiles before Stats and terminal managers close shared leases."
        )
    }

    @Test
    func terminationTeardownRequestCancelsSyncBeforeResourceTeardown() async {
        // Given Sync, RemoteFiles, Stats, and terminal teardown dependencies are
        // injected into the app lifecycle owner.
        let probe = AppLifecycleProbe()
        let coordinator = AppLifecycleCoordinator.makeForTesting(
            disconnectConnectionSessionsBeforeExit: {
                await probe.record("sessions")
            },
            disconnectTerminalTabsBeforeExit: {
                await probe.record("tabs")
            },
            disconnectRemoteFilesBeforeExit: {
                await probe.record("remote-files")
            },
            disconnectStatsBeforeExit: {
                await probe.record("stats")
            },
            cancelSyncBeforeExit: {
                await probe.record("sync")
            }
        )

        // When the platform delegate sends termination intent.
        let requestID = coordinator.requestTerminationTeardown()
        await coordinator.waitForTerminationTeardownRequest(requestID)

        // Then sync tasks are canceled before resource owners start closing.
        #expect(
            await probe.events() == ["sync", "remote-files", "stats", "sessions", "tabs"],
            "Termination should cancel app sync before closing resource owners that sync callbacks may refresh."
        )
    }

    @Test
    func terminationTeardownRequestCancelsVoiceModelDownloadsBeforeResourceTeardown() async {
        // Given Sync, VoiceInput model downloads, RemoteFiles, Stats, and
        // terminal teardown dependencies are injected into the app lifecycle
        // owner.
        let probe = AppLifecycleProbe()
        let coordinator = AppLifecycleCoordinator.makeForTesting(
            disconnectConnectionSessionsBeforeExit: {
                await probe.record("sessions")
            },
            disconnectTerminalTabsBeforeExit: {
                await probe.record("tabs")
            },
            disconnectRemoteFilesBeforeExit: {
                await probe.record("remote-files")
            },
            disconnectStatsBeforeExit: {
                await probe.record("stats")
            },
            cancelSyncBeforeExit: {
                await probe.record("sync")
            },
            cancelStoreBeforeExit: {
                await probe.record("store")
            },
            cancelVoiceModelDownloadsBeforeExit: {
                await probe.record("voice-models")
            }
        )

        // When the platform delegate sends termination intent.
        let requestID = coordinator.requestTerminationTeardown()
        await coordinator.waitForTerminationTeardownRequest(requestID)

        // Then model downloads are canceled before resource owners start
        // closing shared leases and terminal resources.
        #expect(
            await probe.events() == ["sync", "store", "voice-models", "remote-files", "stats", "sessions", "tabs"],
            "Termination should cancel VoiceInput model downloads before closing resource owners."
        )
    }

    @Test
    func terminationTeardownRequestCancelsStoreBeforeVoiceAndResourceTeardown() async {
        // Given Sync, StoreKit, VoiceInput model downloads, RemoteFiles, Stats,
        // and terminal teardown dependencies are injected into the app
        // lifecycle owner.
        let probe = AppLifecycleProbe()
        let coordinator = AppLifecycleCoordinator.makeForTesting(
            disconnectConnectionSessionsBeforeExit: {
                await probe.record("sessions")
            },
            disconnectTerminalTabsBeforeExit: {
                await probe.record("tabs")
            },
            disconnectRemoteFilesBeforeExit: {
                await probe.record("remote-files")
            },
            disconnectStatsBeforeExit: {
                await probe.record("stats")
            },
            cancelSyncBeforeExit: {
                await probe.record("sync")
            },
            cancelStoreBeforeExit: {
                await probe.record("store")
            },
            cancelVoiceModelDownloadsBeforeExit: {
                await probe.record("voice-models")
            }
        )

        // When the platform delegate sends termination intent.
        let requestID = coordinator.requestTerminationTeardown()
        await coordinator.waitForTerminationTeardownRequest(requestID)

        // Then StoreKit cleanup exits before other application resource owners
        // start closing.
        #expect(
            await probe.events() == ["sync", "store", "voice-models", "remote-files", "stats", "sessions", "tabs"],
            "Termination should await StoreKit cleanup before VoiceInput and resource owners start teardown."
        )
    }

    @Test
    func terminationTeardownRequestCancelsAuthBeforeSyncAndResourceTeardown() async {
        // Given Auth, Sync, RemoteFiles, Stats, and terminal teardown
        // dependencies are injected into the app lifecycle owner.
        let probe = AppLifecycleProbe()
        let coordinator = AppLifecycleCoordinator.makeForTesting(
            disconnectConnectionSessionsBeforeExit: {
                await probe.record("sessions")
            },
            disconnectTerminalTabsBeforeExit: {
                await probe.record("tabs")
            },
            disconnectRemoteFilesBeforeExit: {
                await probe.record("remote-files")
            },
            disconnectStatsBeforeExit: {
                await probe.record("stats")
            },
            cancelAuthBeforeExit: {
                await probe.record("auth")
            },
            cancelSyncBeforeExit: {
                await probe.record("sync")
            },
            cancelStoreBeforeExit: {
                await probe.record("store")
            },
            cancelVoiceModelDownloadsBeforeExit: {
                await probe.record("voice-models")
            }
        )

        // When the platform delegate sends termination intent.
        let requestID = coordinator.requestTerminationTeardown()
        await coordinator.waitForTerminationTeardownRequest(requestID)

        // Then auth prompts are canceled before sync callbacks and resource
        // owners start teardown.
        #expect(
            await probe.events() == ["auth", "sync", "store", "voice-models", "remote-files", "stats", "sessions", "tabs"],
            "Termination should cancel auth prompts before sync, StoreKit, VoiceInput downloads, and resource owners start teardown."
        )
    }

    @Test
    func terminationTeardownRequestCompletesAfterTimeoutWhenDisconnectDoesNotFinish() async {
        // Given terminal teardown starts but the first terminal manager does
        // not finish before the app termination timeout.
        let probe = AppLifecycleProbe()
        let releaseDisconnect = AsyncLifecycleGate()
        let releaseTimeout = AsyncLifecycleGate()
        var completionWasCalled = false
        let coordinator = AppLifecycleCoordinator.makeForTesting(
            disconnectConnectionSessionsBeforeExit: {
                await probe.record("sessions-start")
                await releaseDisconnect.wait()
                await probe.record("sessions-end")
            },
            disconnectTerminalTabsBeforeExit: {
                await probe.record("tabs")
            },
            terminationTeardownTimeout: .milliseconds(20),
            sleepForTerminationTimeout: { _ in
                await releaseTimeout.wait()
            }
        )

        // When termination intent arrives and the timeout fires before the
        // first manager finishes.
        let requestID = coordinator.requestTerminationTeardown {
            completionWasCalled = true
        }
        await probe.waitForCount(1)
        await releaseTimeout.open()
        await coordinator.waitForTerminationTeardownRequest(requestID)

        // Then the application termination reply can continue without waiting
        // forever or starting later teardown work after cancellation.
        #expect(
            await probe.events() == ["sessions-start"],
            "Termination timeout should stop waiting before the second terminal manager teardown starts."
        )
        #expect(
            completionWasCalled,
            "Termination completion should be invoked after the timeout releases the tracked request."
        )
        #expect(
            !coordinator.pendingTerminationTeardownRequestIDs.contains(requestID),
            "Termination teardown tracking should clear after timeout completion."
        )

        await releaseDisconnect.open()
        try? await Task.sleep(for: .milliseconds(20))
        #expect(
            !(await probe.events()).contains("tabs"),
            "Canceled timeout teardown should not continue into the second terminal manager after release."
        )
    }

    @Test
    func terminationTeardownHoldsBackgroundLeaseUntilTimeoutCompletes() async {
        // Given termination teardown is protected by an iOS background lease
        // while terminal disconnect work races the app-level timeout.
        let probe = AppLifecycleProbe()
        let backgroundLeaser = RecordingAppBackgroundTaskLeaser()
        let releaseDisconnect = AsyncLifecycleGate()
        let releaseTimeout = AsyncLifecycleGate()
        let coordinator = AppLifecycleCoordinator.makeForTesting(
            disconnectConnectionSessionsBeforeExit: {
                await probe.record("sessions-start")
                await releaseDisconnect.wait()
                await probe.record("sessions-end")
            },
            disconnectTerminalTabsBeforeExit: {
                await probe.record("tabs")
            },
            backgroundTaskLeaser: backgroundLeaser,
            terminationTeardownTimeout: .milliseconds(20),
            sleepForTerminationTimeout: { _ in
                await releaseTimeout.wait()
            }
        )

        // When termination intent starts and teardown has not yet completed.
        let requestID = coordinator.requestTerminationTeardown()
        await probe.waitForCount(1)

        // Then the background lease remains open while the timeout race is
        // still pending.
        #expect(backgroundLeaser.events == ["begin:termination-teardown"])
        #expect(backgroundLeaser.activeLeaseCount == 1)

        await releaseTimeout.open()
        await coordinator.waitForTerminationTeardownRequest(requestID)

        // And the lease is ended when the timeout releases the tracked request.
        #expect(await probe.events() == ["sessions-start"])
        #expect(backgroundLeaser.events == ["begin:termination-teardown", "end:termination-teardown"])
        #expect(backgroundLeaser.activeLeaseCount == 0)

        await releaseDisconnect.open()
    }

    @Test
    func foregroundRefreshRespectsSyncDisabledAndMinimumInterval() async {
        // Given foreground refresh policy is owned by the app lifecycle
        // coordinator.
        let probe = AppLifecycleProbe()
        let policy = AppLifecycleForegroundRefreshPolicyState(
            isSyncEnabled: false,
            currentDate: Date(timeIntervalSince1970: 100)
        )
        let coordinator = AppLifecycleCoordinator.makeForTesting(
            refreshServerData: { reason in
                Task { await probe.record("refresh:\(reason)") }
            },
            isSyncEnabled: { policy.isSyncEnabled },
            now: { policy.currentDate }
        )

        // When sync is disabled, foreground intent arrives, then two enabled
        // foreground intents arrive inside the throttle interval.
        coordinator.requestForegroundRefresh()
        policy.isSyncEnabled = true
        coordinator.requestForegroundRefresh()
        policy.currentDate = Date(timeIntervalSince1970: 110)
        coordinator.requestForegroundRefresh()
        await probe.waitForCount(1)

        // Then only the enabled, unthrottled foreground refresh reaches the
        // sync coordinator.
        #expect(
            await probe.events() == ["refresh:foreground"],
            "Foreground refresh should respect sync-disabled and minimum-interval policy."
        )
    }

    @Test
    func foregroundRefreshRequestsStoreEntitlementsEvenWhenSyncIsDisabled() async {
        // Given CloudKit sync is disabled but Store entitlements may have
        // expired while the app was backgrounded.
        let probe = AppLifecycleProbe()
        let coordinator = AppLifecycleCoordinator.makeForTesting(
            refreshServerData: { reason in
                Task { await probe.record("sync:\(reason)") }
            },
            refreshStoreEntitlements: {
                Task { await probe.record("store-entitlements") }
            },
            isSyncEnabled: { false }
        )

        // When foreground intent arrives.
        coordinator.requestForegroundRefresh()
        await probe.waitForCount(1)

        // Then Store entitlement refresh still runs independently of CloudKit
        // sync availability or throttling.
        #expect(await probe.events() == ["store-entitlements"])
    }

    @Test
    func remoteNotificationCompletionDelegatesToTrackedSyncRefresh() async {
        // Given remote notification refresh is still controlled by the existing
        // app sync coordinator boundary.
        let probe = AppLifecycleProbe()
        let releaseRefresh = AsyncLifecycleGate()
        let coordinator = AppLifecycleCoordinator.makeForTesting(
            refreshServerDataAfterRemoteNotification: {
                await probe.record("refresh-start")
                await releaseRefresh.wait()
                await probe.record("refresh-end")
                return true
            }
        )

        // When remote notification intent arrives.
        let requestID = coordinator.requestRemoteNotificationRefresh { didRefresh in
            await probe.record("completion:\(didRefresh)")
        }
        await probe.waitForCount(1)

        // Then the system completion callback is not invoked until the sync
        // coordinator's tracked refresh completes.
        #expect(
            coordinator.pendingRemoteNotificationRefreshRequestIDs.contains(requestID),
            "Remote notification refresh should stay tracked until sync refresh and completion finish."
        )
        #expect(await probe.events() == ["refresh-start"])
        await releaseRefresh.open()
        await coordinator.waitForRemoteNotificationRefreshRequest(requestID)
        await probe.waitForCount(3)
        #expect(
            await probe.events() == ["refresh-start", "refresh-end", "completion:true"],
            "Remote notification completion should remain behind the tracked sync refresh boundary."
        )
        #expect(
            !coordinator.pendingRemoteNotificationRefreshRequestIDs.contains(requestID),
            "Remote notification tracking should clear only after completion is invoked."
        )
    }
}

@MainActor
private final class AppLifecycleForegroundRefreshPolicyState: @unchecked Sendable {
    var isSyncEnabled: Bool
    var currentDate: Date

    init(isSyncEnabled: Bool, currentDate: Date) {
        self.isSyncEnabled = isSyncEnabled
        self.currentDate = currentDate
    }
}

private actor AppLifecycleProbe {
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

private actor AsyncLifecycleGate {
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

@MainActor
private final class RecordingAppBackgroundTaskLeaser: AppBackgroundTaskLeasing {
    private(set) var events: [String] = []
    private var leases: [RecordingAppBackgroundTaskLease] = []

    var activeLeaseCount: Int {
        leases.filter { !$0.didEnd }.count
    }

    func beginTask(
        named name: String,
        expirationHandler: @escaping @MainActor @Sendable () -> Void
    ) -> any AppBackgroundTaskLease {
        events.append("begin:\(name)")
        let lease = RecordingAppBackgroundTaskLease(
            name: name,
            expirationHandler: expirationHandler,
            onEnd: { [weak self] leaseName in
                self?.events.append("end:\(leaseName)")
            }
        )
        leases.append(lease)
        return lease
    }
}

@MainActor
private final class RecordingAppBackgroundTaskLease: AppBackgroundTaskLease {
    let name: String
    private let expirationHandler: @MainActor @Sendable () -> Void
    private let onEnd: @MainActor (String) -> Void
    private(set) var didEnd = false

    init(
        name: String,
        expirationHandler: @escaping @MainActor @Sendable () -> Void,
        onEnd: @escaping @MainActor (String) -> Void
    ) {
        self.name = name
        self.expirationHandler = expirationHandler
        self.onEnd = onEnd
    }

    func expire() {
        expirationHandler()
        end()
    }

    func end() {
        guard !didEnd else { return }
        didEnd = true
        onEnd(name)
    }
}
