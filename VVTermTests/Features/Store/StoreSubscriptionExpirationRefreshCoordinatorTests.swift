import Foundation
import Testing
@testable import VVTerm

// Test Context:
// These tests protect the Store subscription-expiration refresh scheduler.
// Fakes avoid clocks and StoreKit; update only when expiration-delay tracking,
// awaitable completion, cancellation, or entitlement-refresh handoff ownership
// intentionally changes.

@MainActor
struct StoreSubscriptionExpirationRefreshCoordinatorTests {
    @Test
    func scheduledExpirationRefreshTracksUntilRefreshOperationCompletes() async {
        let sleepGate = SubscriptionExpirationGate()
        let refreshGate = SubscriptionExpirationGate()
        var refreshCount = 0
        let coordinator = StoreSubscriptionExpirationRefreshCoordinator { _ in
            await sleepGate.waitForRelease()
        }

        // Given an active subscription expiration schedules a delayed refresh.
        let requestID = coordinator.scheduleRefresh(at: Date().addingTimeInterval(60)) {
            refreshCount += 1
            await refreshGate.waitForRelease()
        }
        await sleepGate.waitForOperationStart()

        // Then the scheduler keeps the expiration refresh pending while the
        // fake clock is waiting.
        #expect(coordinator.pendingRequestIDs == [requestID])

        // When the fake clock reaches the expiration instant.
        await sleepGate.release()
        await refreshGate.waitForOperationStart()

        // Then the entitlement refresh handoff is still tracked until the
        // refresh operation itself completes.
        #expect(refreshCount == 1)
        #expect(coordinator.pendingRequestIDs == [requestID])

        await refreshGate.release()
        await coordinator.waitForRefresh(requestID)

        #expect(
            coordinator.pendingRequestIDs.isEmpty,
            "Subscription-expiration tracking should clear only after the refresh handoff completes."
        )
    }

    @Test
    func rescheduledExpirationRefreshIgnoresSupersededDelay() async {
        let sleepSequence = SubscriptionExpirationSleepSequence()
        var refreshes: [String] = []
        let coordinator = StoreSubscriptionExpirationRefreshCoordinator { _ in
            await sleepSequence.sleep()
        }

        // Given an existing subscription-expiration refresh is waiting on its
        // delay when a newer expiration intent replaces it.
        let firstRequestID = coordinator.scheduleRefresh(at: Date().addingTimeInterval(60)) {
            refreshes.append("first")
        }
        await sleepSequence.waitForFirstStart()

        let secondRequestID = coordinator.scheduleRefresh(at: Date().addingTimeInterval(120)) {
            refreshes.append("second")
        }
        await sleepSequence.waitForSecondStart()

        // Then only the latest expiration refresh remains owned.
        #expect(firstRequestID != secondRequestID)
        #expect(coordinator.pendingRequestIDs == [secondRequestID])

        // When the superseded delay completes late.
        await sleepSequence.releaseFirst()
        await Task.yield()

        // Then the stale refresh operation must not run.
        #expect(refreshes.isEmpty)
        #expect(coordinator.pendingRequestIDs == [secondRequestID])

        await sleepSequence.releaseSecond()
        await coordinator.waitForRefresh(secondRequestID)

        #expect(refreshes == ["second"])
        #expect(coordinator.pendingRequestIDs.isEmpty)
    }

    @Test
    func waitForSupersededExpirationRefreshAwaitsCanceledDelayCleanup() async {
        let sleepSequence = SubscriptionExpirationCleanupSleepSequence()
        let refreshGate = SubscriptionExpirationGate()
        let coordinator = StoreSubscriptionExpirationRefreshCoordinator { _ in
            await sleepSequence.sleep()
        }

        // Given an expiration refresh is waiting on its delay and performs
        // async cancellation cleanup before the old lifecycle is finished.
        let firstID = coordinator.scheduleRefresh(at: Date().addingTimeInterval(60)) {}
        await sleepSequence.waitForFirstStart()

        // When a newer expiration refresh replaces it.
        let secondID = coordinator.scheduleRefresh(at: Date().addingTimeInterval(120)) {
            await refreshGate.waitForRelease()
        }
        await sleepSequence.waitForSecondStart()

        // Then waiting for the superseded request remains tied to the old task
        // rather than returning only because the visible request ID changed.
        var didFinishWaitingForFirst = false
        let waiter = Task { @MainActor in
            await coordinator.waitForRefresh(firstID)
            didFinishWaitingForFirst = true
        }
        await Task.yield()

        #expect(
            !didFinishWaitingForFirst,
            "Waiting for a superseded expiration refresh should wait for the canceled delay task to exit."
        )

        await sleepSequence.releaseFirstCleanup()
        await waiter.value

        #expect(didFinishWaitingForFirst)
        #expect(coordinator.pendingRequestIDs == [secondID])

        await sleepSequence.releaseSecond()
        await refreshGate.waitForOperationStart()
        await refreshGate.release()
        await coordinator.waitForRefresh(secondID)

        #expect(coordinator.pendingRequestIDs.isEmpty)
    }
}

private actor SubscriptionExpirationGate {
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var hasStarted = false
    private var isReleased = false

    func waitForOperationStart() async {
        guard !hasStarted else { return }
        await withCheckedContinuation { continuation in
            startContinuation = continuation
        }
    }

    func waitForRelease() async {
        guard !hasStarted else {
            await waitUntilReleased()
            return
        }

        hasStarted = true
        startContinuation?.resume()
        startContinuation = nil
        await waitUntilReleased()
    }

    func release() {
        isReleased = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    private func waitUntilReleased() async {
        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }
}

private actor SubscriptionExpirationSleepSequence {
    private let firstGate = SubscriptionExpirationGate()
    private let secondGate = SubscriptionExpirationGate()
    private var sleepCount = 0

    func sleep() async {
        sleepCount += 1
        if sleepCount == 1 {
            await firstGate.waitForRelease()
        } else {
            await secondGate.waitForRelease()
        }
    }

    func waitForFirstStart() async {
        await firstGate.waitForOperationStart()
    }

    func waitForSecondStart() async {
        await secondGate.waitForOperationStart()
    }

    func releaseFirst() async {
        await firstGate.release()
    }

    func releaseSecond() async {
        await secondGate.release()
    }
}

private actor SubscriptionExpirationCleanupSleepSequence {
    private let firstGate = SubscriptionExpirationGate()
    private let firstCleanupGate = SubscriptionExpirationGate()
    private let secondGate = SubscriptionExpirationGate()
    private var sleepCount = 0

    func sleep() async {
        sleepCount += 1
        if sleepCount == 1 {
            await withTaskCancellationHandler {
                await firstGate.waitForRelease()
                if Task.isCancelled {
                    await firstCleanupGate.waitForRelease()
                }
            } onCancel: {
                Task {
                    await self.releaseFirstDelay()
                }
            }
        } else {
            await secondGate.waitForRelease()
        }
    }

    func waitForFirstStart() async {
        await firstGate.waitForOperationStart()
    }

    func waitForSecondStart() async {
        await secondGate.waitForOperationStart()
    }

    func releaseFirstCleanup() async {
        await firstCleanupGate.release()
    }

    func releaseSecond() async {
        await secondGate.release()
    }

    private func releaseFirstDelay() async {
        await firstGate.release()
    }
}
