import Foundation
import Testing
@testable import VVTerm

// Test Context:
// These tests protect the Store entitlement refresh lifecycle owner. Fakes
// avoid StoreKit and clocks; update only when foreground refresh coalescing,
// subscription-expiry follow-up reads, awaitable completion, or cancellation
// intentionally move to another Store application owner.

@MainActor
struct StoreEntitlementRefreshCoordinatorTests {
    @Test
    func subscriptionExpirationRefreshQueuesAfterInFlightForegroundRefresh() async {
        let firstRefreshGate = StoreEntitlementRefreshGate()
        let expiryRefreshGate = StoreEntitlementRefreshGate()
        var refreshCount = 0
        let coordinator = StoreEntitlementRefreshCoordinator {
            refreshCount += 1
            if refreshCount == 1 {
                await firstRefreshGate.waitForRelease()
            } else {
                await expiryRefreshGate.waitForRelease()
            }
        }

        // Given foreground entitlement refresh is already reading StoreKit.
        let foregroundID = coordinator.requestRefresh(reason: .foreground)
        await firstRefreshGate.waitForOperationStart()

        // When subscription expiration fires during that in-flight foreground read.
        let expiryID = coordinator.requestRefresh(reason: .subscriptionExpiration)

        // Then the expiry intent stays owned by the same tracked lifecycle, but
        // is not collapsed into the stale in-flight StoreKit snapshot.
        #expect(expiryID == foregroundID)
        #expect(refreshCount == 1)

        await firstRefreshGate.release()
        for _ in 0..<50 where refreshCount < 2 {
            try? await Task.sleep(for: .milliseconds(10))
        }

        #expect(
            refreshCount == 2,
            "Subscription expiration should force a fresh entitlement read after the in-flight foreground refresh exits."
        )
        #expect(coordinator.pendingRequestIDs == [foregroundID])

        await expiryRefreshGate.release()
        await coordinator.waitForRefresh(foregroundID)

        #expect(coordinator.pendingRequestIDs.isEmpty)
    }
}

private actor StoreEntitlementRefreshGate {
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
