import Foundation
import Testing
@testable import VVTerm

// Test Context:
// These tests protect the Store application-layer owner for user-initiated
// StoreKit requests such as purchase and restore. Fakes avoid StoreKit and
// network I/O; update only when request coalescing, cancellation, awaitable
// completion, or request failure diagnostics intentionally move to another
// Store application owner.

@MainActor
struct StoreRequestLifecycleCoordinatorTests {
    @Test
    func duplicateRequestsCoalesceAndKeepFailureDiagnosticsInOwner() async {
        let gate = StoreRequestLifecycleGate()
        let coordinator = StoreRequestLifecycleCoordinator()
        var operationCount = 0

        // Given a StoreKit request is already in flight under the coordinator.
        let firstID = coordinator.request {
            operationCount += 1
            await gate.waitForRelease()
            throw StoreRequestLifecycleTestError.failed
        }
        let secondID = coordinator.request {
            operationCount += 1
        }
        await gate.waitForOperationStart()

        // Then duplicate user intent reuses the tracked lifecycle instead of
        // starting overlapping StoreKit work.
        #expect(firstID == secondID)
        #expect(operationCount == 1)
        #expect(coordinator.pendingRequestIDs == [firstID])

        await gate.release()
        await coordinator.waitForRequest(firstID)

        #expect(coordinator.pendingRequestIDs.isEmpty)
        #expect(
            coordinator.lastRequestFailure is StoreRequestLifecycleTestError,
            "The lifecycle owner should preserve request failure diagnostics after a failed StoreKit operation."
        )
    }

    @Test
    func cancelAllAndWaitAwaitsTrackedRequestCancellation() async {
        let gate = StoreRequestLifecycleGate()
        let recorder = StoreRequestLifecycleCancellationRecorder()
        let coordinator = StoreRequestLifecycleCoordinator()

        // Given a StoreKit request is suspended inside cancellable work.
        let requestID = coordinator.request {
            await withTaskCancellationHandler {
                await gate.waitForRelease()
            } onCancel: {
                Task {
                    await recorder.record("cancelled")
                    await gate.release()
                }
            }
        }
        await gate.waitForOperationStart()
        #expect(coordinator.pendingRequestIDs == [requestID])

        // When the Store lifecycle owner tears down all tracked request work.
        await coordinator.cancelAllAndWait()

        // Then the request task has exited before cleanup returns.
        #expect(coordinator.pendingRequestIDs.isEmpty)
        #expect(await recorder.events() == ["cancelled"])
    }
}

private actor StoreRequestLifecycleGate {
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
        markStarted()
        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func release() {
        isReleased = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    private func markStarted() {
        guard !hasStarted else { return }
        hasStarted = true
        startContinuation?.resume()
        startContinuation = nil
    }
}

private actor StoreRequestLifecycleCancellationRecorder {
    private var recordedEvents: [String] = []

    func record(_ event: String) {
        recordedEvents.append(event)
    }

    func events() -> [String] {
        recordedEvents
    }
}

private enum StoreRequestLifecycleTestError: Error {
    case failed
}
