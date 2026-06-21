import Testing
@testable import VVTerm

// Test Context:
// These tests protect StoreManager as the application-layer owner for StoreKit
// purchase and restore request lifecycle. Fakes avoid real StoreKit products,
// AppStore.sync, transaction streams, and network I/O. Update these tests only
// when purchase/restore request ownership intentionally moves to another Store
// application owner with equivalent pending-request tracking, awaitable
// completion, and request-failure diagnostics.
@MainActor
@Suite
struct StoreManagerLifecycleTests {
    @Test
    func purchaseRequestTracksPendingOperationUntilCompletion() async {
        let manager = StoreManager.makeForTesting()
        let gate = StoreRequestGate()
        var didRunPurchase = false

        // Given SwiftUI sends purchase intent through StoreManager.
        let requestID = manager.requestPurchaseForTesting {
            didRunPurchase = true
            await gate.waitForRelease()
        }

        await gate.waitForOperationStart()

        // Then the Store application owner tracks the pending request and makes
        // completion awaitable for ordering-sensitive tests or callers.
        #expect(
            manager.pendingPurchaseRequestIDs.contains(requestID),
            "A user-initiated purchase must stay tracked while the operation is pending."
        )

        await gate.release()
        await manager.waitForPurchaseRequest(requestID)

        #expect(didRunPurchase, "The tracked purchase request should execute the supplied operation.")
        #expect(
            !manager.pendingPurchaseRequestIDs.contains(requestID),
            "StoreManager should clear the purchase request after completion."
        )
        #expect(
            manager.lastPurchaseRequestFailure == nil,
            "Successful purchase requests should not leave stale request failure diagnostics."
        )
    }

    @Test
    func restoreRequestTracksFailureAndClearsPendingRequest() async {
        let manager = StoreManager.makeForTesting()
        let gate = StoreRequestGate()

        // Given StoreManager owns a restore request whose underlying operation
        // fails before StoreKit state can be updated.
        let requestID = manager.requestRestorePurchasesForTesting {
            await gate.waitForRelease()
            throw StoreRequestTestError.restoreFailed
        }

        await gate.waitForOperationStart()
        #expect(
            manager.pendingRestoreRequestIDs.contains(requestID),
            "A user-initiated restore must stay tracked while the operation is pending."
        )

        await gate.release()
        await manager.waitForRestoreRequest(requestID)

        // Then request-level failure diagnostics remain in the application
        // owner instead of disappearing in a SwiftUI-owned task.
        #expect(
            !manager.pendingRestoreRequestIDs.contains(requestID),
            "StoreManager should clear the restore request after a failed operation."
        )
        #expect(
            manager.lastRestoreRequestFailure is StoreRequestTestError,
            "StoreManager should record restore request failures for diagnostics and tests."
        )
    }

    @Test
    func purchaseCancellationDoesNotBecomeFailedState() {
        let manager = StoreManager.makeForTesting()
        manager.purchaseState = .purchasing

        // Given StoreKit purchase work is cancelled by lifecycle teardown or
        // system cancellation rather than a purchase failure.
        manager.applyPurchaseErrorForTesting(CancellationError())

        // Then cancellation should return purchase UI to idle, not show a
        // misleading failed purchase state.
        #expect(
            manager.purchaseState == .idle,
            "Store purchase cancellation must remain distinct from failed StoreKit operations."
        )
    }

    @Test
    func restoreCancellationDoesNotBecomeFailedState() {
        let manager = StoreManager.makeForTesting()
        manager.restoreState = .restoring

        // Given App Store restore work is cancelled by lifecycle teardown or
        // system cancellation rather than a restore failure.
        manager.applyRestoreErrorForTesting(CancellationError())

        // Then cancellation should return restore UI to idle, not show a
        // misleading failed restore state.
        #expect(
            manager.restoreState == .idle,
            "Store restore cancellation must remain distinct from failed StoreKit operations."
        )
    }
}

private actor StoreRequestGate {
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

    func markOperationStarted() {
        guard !hasStarted else { return }
        hasStarted = true
        startContinuation?.resume()
        startContinuation = nil
    }

    func waitForRelease() async {
        markOperationStarted()
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
}

private enum StoreRequestTestError: Error {
    case restoreFailed
}
