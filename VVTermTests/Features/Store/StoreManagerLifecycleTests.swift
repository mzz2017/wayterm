import Testing
@testable import VVTerm

// Test Context:
// These tests protect StoreManager as the application-layer owner for StoreKit
// purchase, restore, startup refresh, review-mode refresh, and paywall product
// load lifecycle. Fakes avoid real StoreKit products, AppStore.sync,
// transaction streams, and network I/O. Update these tests only when Store
// lifecycle ownership intentionally moves to another application owner with
// equivalent pending-task tracking, awaitable completion, request coalescing,
// and request-failure diagnostics.
@MainActor
@Suite
struct StoreManagerLifecycleTests {
    @Test
    func productLoadRequestTracksOperationUntilCompletion() async {
        let gate = StoreRequestGate()
        var didLoadProducts = false
        let manager = StoreManager.makeForTesting(
            loadProductsAction: { _ in
                didLoadProducts = true
                await gate.waitForRelease()
            }
        )

        // Given SwiftUI sends paywall product-load intent through StoreManager.
        let requestID = manager.requestProductLoad()

        await gate.waitForOperationStart()

        // Then StoreManager tracks the pending product load until the fake
        // StoreKit work exits, making completion awaitable.
        #expect(
            manager.pendingProductLoadRequestIDs.contains(requestID),
            "A paywall product-load request must stay tracked while StoreKit product loading is pending."
        )

        await gate.release()
        await manager.waitForProductLoadRequest(requestID)

        #expect(didLoadProducts, "The tracked product-load request should execute the configured load action.")
        #expect(
            !manager.pendingProductLoadRequestIDs.contains(requestID),
            "StoreManager should clear product-load request tracking after completion."
        )
    }

    @Test
    func duplicateProductLoadRequestsCoalesceUntilCompletion() async {
        let gate = StoreRequestGate()
        var loadCount = 0
        var completions: [String] = []
        let manager = StoreManager.makeForTesting(
            loadProductsAction: { _ in
                loadCount += 1
                await gate.waitForRelease()
            }
        )

        // Given the paywall appears twice while the first product load is
        // still pending.
        let firstID = manager.requestProductLoad {
            completions.append("first")
        }
        let secondID = manager.requestProductLoad {
            completions.append("second")
        }

        await gate.waitForOperationStart()

        // Then both callers observe the same StoreManager-owned request
        // instead of starting duplicate App Store product fetches.
        #expect(
            firstID == secondID,
            "Duplicate paywall product-load intent should coalesce to the existing request ID."
        )
        #expect(loadCount == 1, "Duplicate product-load intent should run the fake StoreKit load once.")
        #expect(
            manager.pendingProductLoadRequestIDs == [firstID],
            "Only the coalesced product-load request should be visible as pending."
        )

        await gate.release()
        await manager.waitForProductLoadRequest(firstID)

        #expect(
            completions == ["first", "second"],
            "Every coalesced product-load caller should receive its completion callback after loading exits."
        )
        #expect(
            !manager.pendingProductLoadRequestIDs.contains(firstID),
            "StoreManager should clear the coalesced product-load request after completion."
        )
    }

    @Test
    func productLoadCancellationDoesNotRunCompletionOrRecordPurchaseRestoreFailure() async {
        let gate = StoreRequestGate()
        var didRunCompletion = false
        let manager = StoreManager.makeForTesting(
            loadProductsAction: { _ in
                await gate.waitForRelease()
            }
        )

        // Given lifecycle teardown cancels a pending product-load request.
        let requestID = manager.requestProductLoad {
            didRunCompletion = true
        }
        await gate.waitForOperationStart()
        manager.cancelProductLoadRequestForTesting(requestID)

        await gate.release()
        await manager.waitForProductLoadRequest(requestID)

        // Then cancellation is lifecycle completion, not a purchase/restore
        // failure, and stale presentation callbacks are not fired.
        #expect(!didRunCompletion, "Canceled product-load requests should not run presentation callbacks.")
        #expect(
            !manager.pendingProductLoadRequestIDs.contains(requestID),
            "StoreManager should clear canceled product-load request tracking after the task exits."
        )
        #expect(
            manager.lastPurchaseRequestFailure == nil,
            "Product-load cancellation should not be recorded as a purchase request failure."
        )
        #expect(
            manager.lastRestoreRequestFailure == nil,
            "Product-load cancellation should not be recorded as a restore request failure."
        )
    }

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

    @Test
    func startupRefreshTracksLoadAndEntitlementsUntilCompletion() async {
        let loadGate = StoreRequestGate()
        let entitlementGate = StoreRequestGate()
        var operationOrder: [String] = []

        // Given StoreManager starts its launch refresh with fake StoreKit work
        // that stays pending until the test releases each phase.
        let manager = StoreManager.makeForTesting(
            startBackgroundTasks: true,
            loadProductsAction: { _ in
                operationOrder.append("load")
                await loadGate.waitForRelease()
            },
            checkEntitlementsAction: { _ in
                operationOrder.append("entitlements")
                await entitlementGate.waitForRelease()
            }
        )

        await loadGate.waitForOperationStart()
        #expect(
            manager.hasPendingStartupRefreshForTesting,
            "Store startup refresh must stay tracked while product loading is pending."
        )

        await loadGate.release()
        await entitlementGate.waitForOperationStart()
        #expect(
            operationOrder == ["load", "entitlements"],
            "Store startup refresh should load products before checking entitlements."
        )
        #expect(
            manager.hasPendingStartupRefreshForTesting,
            "Store startup refresh must stay tracked while entitlement checking is pending."
        )

        await entitlementGate.release()
        await manager.waitForStartupRefreshForTesting()

        #expect(
            !manager.hasPendingStartupRefreshForTesting,
            "StoreManager should clear startup refresh tracking after completion."
        )
    }

    @Test
    func disablingReviewModeTracksEntitlementRefreshUntilCompletion() async {
        let entitlementGate = StoreRequestGate()
        var entitlementRefreshCount = 0
        let manager = StoreManager.makeForTesting(
            checkEntitlementsAction: { _ in
                entitlementRefreshCount += 1
                await entitlementGate.waitForRelease()
            }
        )

        // Given review mode is enabled and then disabled by user/app intent.
        #expect(manager.enableReviewMode(code: StoreManager.reviewModeCode))
        manager.setReviewModeEnabled(false)

        await entitlementGate.waitForOperationStart()
        #expect(
            manager.hasPendingReviewModeRefreshForTesting,
            "Disabling review mode must track the entitlement refresh while it is pending."
        )

        await entitlementGate.release()
        await manager.waitForReviewModeRefreshForTesting()

        #expect(entitlementRefreshCount == 1, "Review-mode disable should request one entitlement refresh.")
        #expect(
            !manager.hasPendingReviewModeRefreshForTesting,
            "StoreManager should clear review-mode refresh tracking after completion."
        )
    }

    @Test
    func disablingReviewModeCancelsSupersededEntitlementRefreshBeforeItRuns() async {
        let recorder = StoreRefreshRecorder()
        let manager = StoreManager.makeForTesting(
            checkEntitlementsAction: { _ in
                await recorder.recordRefresh()
            }
        )

        // Given review mode is disabled twice before the first queued refresh
        // gets a chance to run.
        #expect(manager.enableReviewMode(code: StoreManager.reviewModeCode))
        manager.setReviewModeEnabled(false)
        #expect(manager.enableReviewMode(code: StoreManager.reviewModeCode))
        manager.setReviewModeEnabled(false)

        await manager.waitForReviewModeRefreshForTesting()
        await Task.yield()

        let refreshCount = await recorder.refreshCount()
        #expect(
            refreshCount == 1,
            "A superseded review-mode refresh task must not run entitlement work after cancellation."
        )
    }

    @Test
    func storeTelemetryIsInjectedForPaywallReviewAndLaunchEvents() async {
        let telemetry = StoreTelemetrySpy()
        let manager = StoreManager.makeForTesting(telemetry: telemetry)

        manager.notePaywallPresented(source: .postFirstConnection)
        manager.requestReviewAfterPurchase()
        await manager.checkEntitlements()

        #expect(
            telemetry.paywallSources == [.postFirstConnection],
            "StoreManager should record paywall presentation through its injected telemetry service."
        )
        #expect(
            telemetry.reviewAfterPurchaseRequestCount == 1,
            "Post-purchase review requests should go through injected Store telemetry instead of UI-owned engagement singletons."
        )
        #expect(
            telemetry.launchedProStates == [false],
            "Entitlement refresh should record launch/pro state through injected Store telemetry."
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

private actor StoreRefreshRecorder {
    private var count = 0

    func recordRefresh() {
        count += 1
    }

    func refreshCount() -> Int {
        count
    }
}

@MainActor
private final class StoreTelemetrySpy: StoreTelemetry {
    private(set) var paywallSources: [PaywallSource] = []
    private(set) var purchasedProducts: [(source: PaywallSource, productId: String)] = []
    private(set) var launchedProStates: [Bool] = []
    private(set) var reviewAfterPurchaseRequestCount = 0

    func notePaywallPresented(source: PaywallSource) {
        paywallSources.append(source)
    }

    func trackPurchase(source: PaywallSource, productId: String) {
        purchasedProducts.append((source: source, productId: productId))
    }

    func trackAppLaunched(isPro: Bool) {
        launchedProStates.append(isPro)
    }

    func requestReviewAfterPurchase() {
        reviewAfterPurchaseRequestCount += 1
    }
}
