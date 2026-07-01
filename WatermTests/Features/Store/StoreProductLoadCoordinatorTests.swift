import Foundation
import Testing
@testable import Waterm

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

    @Test
    func completionTriggeredProductLoadStartsFreshLifecycleRequest() async {
        let firstGate = ProductLoadGate()
        let secondGate = ProductLoadGate()
        var loadCount = 0
        var completions: [String] = []
        let coordinator = StoreProductLoadCoordinator {
            loadCount += 1
            if loadCount == 1 {
                await firstGate.waitForRelease()
            } else {
                await secondGate.waitForRelease()
            }
        }
        var secondID: UUID?

        // Given a product-load completion immediately asks for products again,
        // such as a paywall refreshing choices after presentation state changes.
        let firstID = coordinator.requestLoad {
            completions.append("first")
            secondID = coordinator.requestLoad {
                completions.append("second")
            }
        }
        await firstGate.waitForOperationStart()

        // When the first load finishes and runs its completion callback.
        await firstGate.release()
        for _ in 0..<50 where secondID == nil {
            try? await Task.sleep(for: .milliseconds(10))
        }

        // Then the new intent must start a fresh lifecycle request instead of
        // being silently coalesced into the finishing request callback snapshot.
        #expect(secondID != nil)
        #expect(secondID != firstID)
        #expect(loadCount == 2)
        #expect(coordinator.pendingRequestIDs == Set(secondID.map { [$0] } ?? []))

        await secondGate.release()
        if let secondID {
            await coordinator.waitForLoad(secondID)
        }

        #expect(
            completions == ["first", "second"],
            "A completion-triggered product load should run its own load operation and callback."
        )
        #expect(coordinator.pendingRequestIDs.isEmpty)
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
