import Foundation
import Testing
@testable import VVTerm

// Test Context:
// These tests protect Store background refresh task ownership. Fakes avoid
// StoreKit and app lifecycle callbacks; update only when startup/review-mode
// refresh pending tracking, awaitable completion, cancellation, or independent
// kind ownership intentionally changes.

@MainActor
struct StoreBackgroundRefreshCoordinatorTests {
    @Test
    func startupRefreshTracksUntilOperationCompletes() async {
        let gate = BackgroundRefreshGate()
        var runCount = 0
        let coordinator = StoreBackgroundRefreshCoordinator()

        // Given Store starts a startup refresh.
        let requestID = coordinator.startRefresh(kind: .startup) {
            runCount += 1
            await gate.waitForRelease()
        }
        await gate.waitForOperationStart()

        // Then the startup refresh remains pending while StoreKit work is active.
        #expect(runCount == 1)
        #expect(coordinator.pendingRequestIDs(for: .startup) == [requestID])

        await gate.release()
        await coordinator.waitForRefresh(kind: .startup, requestID)

        #expect(
            coordinator.pendingRequestIDs(for: .startup).isEmpty,
            "Startup refresh tracking should clear only after the refresh exits."
        )
    }

    @Test
    func restartingSameKindCancelsSupersededRefresh() async {
        let firstGate = BackgroundRefreshGate()
        let secondGate = BackgroundRefreshGate()
        let recorder = BackgroundRefreshCancellationRecorder()
        let coordinator = StoreBackgroundRefreshCoordinator()

        // Given a review-mode refresh is active.
        let firstID = coordinator.startRefresh(kind: .reviewMode) {
            await withTaskCancellationHandler {
                await firstGate.waitForRelease()
            } onCancel: {
                Task {
                    await recorder.record("first-cancelled")
                    await firstGate.release()
                }
            }
        }
        await firstGate.waitForOperationStart()

        // When a newer review-mode refresh replaces it.
        let secondID = coordinator.startRefresh(kind: .reviewMode) {
            await secondGate.waitForRelease()
        }
        await secondGate.waitForOperationStart()
        await recorder.waitForEvents(["first-cancelled"])

        // Then only the latest refresh of that kind remains pending.
        #expect(firstID != secondID)
        #expect(coordinator.pendingRequestIDs(for: .reviewMode) == [secondID])

        await secondGate.release()
        await coordinator.waitForRefresh(kind: .reviewMode, secondID)

        #expect(coordinator.pendingRequestIDs(for: .reviewMode).isEmpty)
    }

    @Test
    func differentKindsRemainIndependentlyTracked() async {
        let startupGate = BackgroundRefreshGate()
        let reviewGate = BackgroundRefreshGate()
        let coordinator = StoreBackgroundRefreshCoordinator()

        // Given startup and review-mode refreshes are active at the same time.
        let startupID = coordinator.startRefresh(kind: .startup) {
            await startupGate.waitForRelease()
        }
        let reviewID = coordinator.startRefresh(kind: .reviewMode) {
            await reviewGate.waitForRelease()
        }
        await startupGate.waitForOperationStart()
        await reviewGate.waitForOperationStart()

        // Then each lifecycle is tracked by its own kind.
        #expect(coordinator.pendingRequestIDs(for: .startup) == [startupID])
        #expect(coordinator.pendingRequestIDs(for: .reviewMode) == [reviewID])

        await startupGate.release()
        await coordinator.waitForRefresh(kind: .startup, startupID)

        #expect(coordinator.pendingRequestIDs(for: .startup).isEmpty)
        #expect(coordinator.pendingRequestIDs(for: .reviewMode) == [reviewID])

        await reviewGate.release()
        await coordinator.waitForRefresh(kind: .reviewMode, reviewID)

        #expect(coordinator.pendingRequestIDs(for: .reviewMode).isEmpty)
    }
}

private actor BackgroundRefreshGate {
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

private actor BackgroundRefreshCancellationRecorder {
    private var recordedEvents: [String] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func record(_ event: String) {
        recordedEvents.append(event)
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }

    func waitForEvents(_ expectedEvents: [String]) async {
        while recordedEvents != expectedEvents {
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }
    }
}
