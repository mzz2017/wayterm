import Foundation
import Testing
@testable import VVTerm

// Test Context:
// These tests protect the Store transaction-listener lifecycle owner. Fakes
// avoid StoreKit streams; update only when listener pending tracking, awaitable
// completion, cancellation, or replacement semantics intentionally change.

@MainActor
struct StoreTransactionListenerCoordinatorTests {
    @Test
    func listenerTracksUntilOperationCompletes() async {
        let gate = TransactionListenerGate()
        var startCount = 0
        let coordinator = StoreTransactionListenerCoordinator()

        // Given Store starts a long-lived transaction listener.
        let listenerID = coordinator.startListening {
            startCount += 1
            await gate.waitForRelease()
        }
        await gate.waitForOperationStart()

        // Then the listener remains tracked while the stream is active.
        #expect(startCount == 1)
        #expect(coordinator.pendingRequestIDs == [listenerID])

        await gate.release()
        await coordinator.waitForListener(listenerID)

        #expect(
            coordinator.pendingRequestIDs.isEmpty,
            "Transaction listener tracking should clear only after the listener exits."
        )
    }

    @Test
    func restartingListenerCancelsSupersededListener() async {
        let firstGate = TransactionListenerGate()
        let secondGate = TransactionListenerGate()
        let recorder = TransactionListenerCancellationRecorder()
        let coordinator = StoreTransactionListenerCoordinator()

        // Given an existing transaction listener is active.
        let firstID = coordinator.startListening {
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

        // When a new listener replaces it.
        let secondID = coordinator.startListening {
            await secondGate.waitForRelease()
        }
        await secondGate.waitForOperationStart()
        await recorder.waitForEvents(["first-cancelled"])

        // Then only the latest listener remains owned, and the stale listener
        // observed cancellation.
        #expect(firstID != secondID)
        #expect(await recorder.events() == ["first-cancelled"])
        #expect(coordinator.pendingRequestIDs == [secondID])

        await secondGate.release()
        await coordinator.waitForListener(secondID)

        #expect(coordinator.pendingRequestIDs.isEmpty)
    }
}

private actor TransactionListenerGate {
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

private actor TransactionListenerCancellationRecorder {
    private var recordedEvents: [String] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func record(_ event: String) {
        recordedEvents.append(event)
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }

    func events() -> [String] {
        recordedEvents
    }

    func waitForEvents(_ expectedEvents: [String]) async {
        while recordedEvents != expectedEvents {
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }
    }
}
