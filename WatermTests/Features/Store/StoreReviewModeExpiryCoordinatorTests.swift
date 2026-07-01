import Foundation
import Testing
@testable import Waterm

// Test Context:
// These tests protect the Store review-mode expiry scheduler. Fakes avoid
// clocks and StoreKit; update only when review-mode expiry tracking, awaitable
// completion, cancellation, or stale-expiry suppression intentionally changes.

@MainActor
struct StoreReviewModeExpiryCoordinatorTests {
    @Test
    func scheduledExpiryTracksUntilExpiryOperationCompletes() async {
        let sleepGate = ReviewModeExpiryGate()
        let expiryGate = ReviewModeExpiryGate()
        var expiryCount = 0
        let coordinator = StoreReviewModeExpiryCoordinator { _ in
            await sleepGate.waitForRelease()
        }

        // Given review mode schedules a delayed expiry operation.
        let requestID = coordinator.scheduleExpiry(at: Date().addingTimeInterval(60)) {
            expiryCount += 1
            await expiryGate.waitForRelease()
        }
        await sleepGate.waitForOperationStart()

        // Then the scheduler keeps the expiry pending while the fake clock is
        // waiting.
        #expect(coordinator.pendingRequestIDs == [requestID])

        // When the fake clock reaches the expiry instant.
        await sleepGate.release()
        await expiryGate.waitForOperationStart()

        // Then the expiry handoff is still tracked until the operation itself
        // completes.
        #expect(expiryCount == 1)
        #expect(coordinator.pendingRequestIDs == [requestID])

        await expiryGate.release()
        await coordinator.waitForExpiry(requestID)

        #expect(
            coordinator.pendingRequestIDs.isEmpty,
            "Review-mode expiry tracking should clear only after the expiry operation completes."
        )
    }

    @Test
    func rescheduledExpiryIgnoresSupersededDelay() async {
        let sleepSequence = ReviewModeExpirySleepSequence()
        var expiries: [String] = []
        let coordinator = StoreReviewModeExpiryCoordinator { _ in
            await sleepSequence.sleep()
        }

        // Given an existing review-mode expiry is waiting on its delay when a
        // newer expiry intent replaces it.
        let firstRequestID = coordinator.scheduleExpiry(at: Date().addingTimeInterval(60)) {
            expiries.append("first")
        }
        await sleepSequence.waitForFirstStart()

        let secondRequestID = coordinator.scheduleExpiry(at: Date().addingTimeInterval(120)) {
            expiries.append("second")
        }
        await sleepSequence.waitForSecondStart()

        // Then only the latest expiry remains owned.
        #expect(firstRequestID != secondRequestID)
        #expect(coordinator.pendingRequestIDs == [secondRequestID])

        // When the superseded delay completes late.
        await sleepSequence.releaseFirst()
        await Task.yield()

        // Then the stale expiry operation must not run.
        #expect(expiries.isEmpty)
        #expect(coordinator.pendingRequestIDs == [secondRequestID])

        await sleepSequence.releaseSecond()
        await coordinator.waitForExpiry(secondRequestID)

        #expect(expiries == ["second"])
        #expect(coordinator.pendingRequestIDs.isEmpty)
    }

    @Test
    func waitForSupersededExpiryAwaitsCanceledDelayCleanup() async {
        let sleepSequence = ReviewModeExpiryCleanupSleepSequence()
        let expiryGate = ReviewModeExpiryGate()
        let coordinator = StoreReviewModeExpiryCoordinator { _ in
            await sleepSequence.sleep()
        }

        // Given a review-mode expiry is waiting on its delay and performs async
        // cancellation cleanup before the old lifecycle is finished.
        let firstID = coordinator.scheduleExpiry(at: Date().addingTimeInterval(60)) {}
        await sleepSequence.waitForFirstStart()

        // When a newer expiry replaces it.
        let secondID = coordinator.scheduleExpiry(at: Date().addingTimeInterval(120)) {
            await expiryGate.waitForRelease()
        }
        await sleepSequence.waitForSecondStart()

        // Then waiting for the superseded request remains tied to the old task
        // instead of returning only because the visible request ID changed.
        var didFinishWaitingForFirst = false
        let waiter = Task { @MainActor in
            await coordinator.waitForExpiry(firstID)
            didFinishWaitingForFirst = true
        }
        await Task.yield()

        #expect(
            !didFinishWaitingForFirst,
            "Waiting for a superseded review-mode expiry should wait for the canceled delay task to exit."
        )

        await sleepSequence.releaseFirstCleanup()
        await waiter.value

        #expect(didFinishWaitingForFirst)
        #expect(coordinator.pendingRequestIDs == [secondID])

        await sleepSequence.releaseSecond()
        await expiryGate.waitForOperationStart()
        await expiryGate.release()
        await coordinator.waitForExpiry(secondID)

        #expect(coordinator.pendingRequestIDs.isEmpty)
    }
}

private actor ReviewModeExpiryGate {
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

private actor ReviewModeExpirySleepSequence {
    private let first = ReviewModeExpiryGate()
    private let second = ReviewModeExpiryGate()
    private var sleepCount = 0

    func sleep() async {
        sleepCount += 1
        if sleepCount == 1 {
            await first.waitForRelease()
        } else {
            await second.waitForRelease()
        }
    }

    func waitForFirstStart() async {
        await first.waitForOperationStart()
    }

    func waitForSecondStart() async {
        await second.waitForOperationStart()
    }

    func releaseFirst() async {
        await first.release()
    }

    func releaseSecond() async {
        await second.release()
    }
}

private actor ReviewModeExpiryCleanupSleepSequence {
    private let first = ReviewModeExpiryGate()
    private let firstCleanup = ReviewModeExpiryGate()
    private let second = ReviewModeExpiryGate()
    private var sleepCount = 0

    func sleep() async {
        sleepCount += 1
        if sleepCount == 1 {
            await withTaskCancellationHandler {
                await first.waitForRelease()
                if Task.isCancelled {
                    await firstCleanup.waitForRelease()
                }
            } onCancel: {
                Task {
                    await self.releaseFirstDelay()
                }
            }
        } else {
            await second.waitForRelease()
        }
    }

    func waitForFirstStart() async {
        await first.waitForOperationStart()
    }

    func waitForSecondStart() async {
        await second.waitForOperationStart()
    }

    func releaseFirstCleanup() async {
        await firstCleanup.release()
    }

    func releaseSecond() async {
        await second.release()
    }

    private func releaseFirstDelay() async {
        await first.release()
    }
}
