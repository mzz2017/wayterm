import Foundation
import Testing
@testable import VVTerm

// Test Context:
// These tests protect the paywall product-load lifecycle owner. Fakes avoid
// StoreKit product fetches; update only when product-load coalescing,
// completion callbacks, awaitable completion, or cancellation ownership
// intentionally changes.

@MainActor
struct StoreProductLoadCoordinatorTests {
    @Test
    func duplicateProductLoadRequestsCoalesceAndRunAllCompletionsAfterLoad() async {
        let gate = ProductLoadGate()
        let coordinator = StoreProductLoadCoordinator {
            await gate.waitForRelease()
        }
        var completions: [String] = []

        // Given the paywall asks for products twice while the first load is
        // still pending.
        let firstID = coordinator.requestLoad {
            completions.append("first")
        }
        let secondID = coordinator.requestLoad {
            completions.append("second")
        }
        await gate.waitForOperationStart()

        // Then both callers share one lifecycle request owner.
        #expect(firstID == secondID)
        #expect(coordinator.pendingRequestIDs == [firstID])

        // And every callback runs after the load operation exits.
        await gate.release()
        await coordinator.waitForLoad(firstID)

        #expect(
            completions == ["first", "second"],
            "Every coalesced paywall product-load caller should receive its completion callback after loading exits."
        )
        #expect(
            coordinator.pendingRequestIDs.isEmpty,
            "Product-load request tracking should clear after the coalesced load completes."
        )
    }
}

private actor ProductLoadGate {
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
