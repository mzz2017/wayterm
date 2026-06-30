import StoreKit
import Foundation
import Combine
import os.log

// MARK: - Store Manager

@MainActor
final class StoreManager: ObservableObject {
    private typealias StoreLifecycleAction = @MainActor (StoreManager) async -> Void
    private typealias StoreTransactionListenerAction = @MainActor (StoreManager) async -> Void

    static let shared = StoreManager()
    static let reviewModeCode = ReviewModeCode.value

    @Published var isPro: Bool = false
    @Published var isLifetime: Bool = false
    @Published var subscriptionStatus: Product.SubscriptionInfo.Status?
    @Published var products: [Product] = []
    @Published var purchaseState: PurchaseState = .idle
    @Published var restoreState: RestoreState = .idle
    @Published private(set) var isReviewModeEnabled: Bool = false
    @Published private(set) var lastPurchasedProductId: String?
    private(set) var activePaywallSource: PaywallSource = .general
    private(set) var hasPresentedPaywallThisLaunch = false
    private var purchaseRequestTasks: [UUID: Task<Void, Never>] = [:]
    private var restoreRequestTasks: [UUID: Task<Void, Never>] = [:]
    private var purchaseRequestID: UUID?
    private var restoreRequestID: UUID?
    private(set) var lastPurchaseRequestFailure: Error?
    private(set) var lastRestoreRequestFailure: Error?
    var pendingPurchaseRequestIDs: Set<UUID> { Set(purchaseRequestTasks.keys) }
    var pendingRestoreRequestIDs: Set<UUID> { Set(restoreRequestTasks.keys) }
    var pendingProductLoadRequestIDs: Set<UUID> {
        guard let productLoadRequestID else { return [] }
        return [productLoadRequestID]
    }

    private var startupRefreshTask: Task<Void, Never>?
    private var startupRefreshTaskID: UUID?
    private var reviewModeRefreshTask: Task<Void, Never>?
    private var reviewModeRefreshTaskID: UUID?
    private var productLoadRequestTask: Task<Void, Never>?
    private var productLoadRequestID: UUID?
    private var productLoadCompletionCallbacks: [@MainActor () -> Void] = []
    private var updateListenerTask: Task<Void, Never>?
    private var updateListenerTaskID: UUID?
    private var reviewModeExpiryTask: Task<Void, Never>?
    private var reviewModeExpiresAt: Date?
    private var entitlementRefreshGeneration = 0
    private let loadProductsAction: StoreLifecycleAction
    private let checkEntitlementsAction: StoreLifecycleAction
    private let transactionListenerAction: StoreTransactionListenerAction
    private let telemetry: any StoreTelemetry
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "Store")
    private let reviewModeDuration: TimeInterval = 60 * 60 * 5

    // MARK: - Sorted Products

    var monthlyProduct: Product? {
        products.first { $0.id == VVTermProducts.proMonthly }
    }

    var yearlyProduct: Product? {
        products.first { $0.id == VVTermProducts.proYearly }
    }

    var lifetimeProduct: Product? {
        products.first { $0.id == VVTermProducts.proLifetime }
    }

    // MARK: - Initialization

    private init(
        startBackgroundTasks: Bool = true,
        loadProductsAction: StoreLifecycleAction? = nil,
        checkEntitlementsAction: StoreLifecycleAction? = nil,
        transactionListenerAction: StoreTransactionListenerAction? = nil,
        telemetry: (any StoreTelemetry)? = nil
    ) {
        self.loadProductsAction = loadProductsAction ?? { manager in
            await manager.loadProducts()
        }
        self.checkEntitlementsAction = checkEntitlementsAction ?? { manager in
            await manager.checkEntitlements()
        }
        self.transactionListenerAction = transactionListenerAction ?? { manager in
            await manager.listenForLiveTransactions()
        }
        self.telemetry = telemetry ?? LiveStoreTelemetry.shared

        if startBackgroundTasks {
            updateListenerTask = listenForTransactions()
            startStartupRefresh()
        }
    }

    deinit {
        updateListenerTask?.cancel()
        startupRefreshTask?.cancel()
        reviewModeRefreshTask?.cancel()
        reviewModeExpiryTask?.cancel()
        productLoadRequestTask?.cancel()
        purchaseRequestTasks.values.forEach { $0.cancel() }
        restoreRequestTasks.values.forEach { $0.cancel() }
    }

    func cancelAllAndWait() async {
        let trackedTasks = [
            updateListenerTask,
            startupRefreshTask,
            reviewModeRefreshTask,
            reviewModeExpiryTask,
            productLoadRequestTask
        ].compactMap { $0 }
            + purchaseRequestTasks.values
            + restoreRequestTasks.values

        trackedTasks.forEach { $0.cancel() }
        for task in trackedTasks {
            await task.value
        }

        updateListenerTask = nil
        updateListenerTaskID = nil
        startupRefreshTask = nil
        startupRefreshTaskID = nil
        reviewModeRefreshTask = nil
        reviewModeRefreshTaskID = nil
        reviewModeExpiryTask = nil
        productLoadRequestTask = nil
        productLoadRequestID = nil
        productLoadCompletionCallbacks = []
        purchaseRequestID = nil
        restoreRequestID = nil
        purchaseRequestTasks.removeAll()
        restoreRequestTasks.removeAll()
    }

    private func startStartupRefresh() {
        startupRefreshTask?.cancel()
        let taskID = UUID()
        startupRefreshTaskID = taskID

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.startupRefreshTaskID == taskID {
                    self.startupRefreshTaskID = nil
                    self.startupRefreshTask = nil
                }
            }

            await self.loadProductsAction(self)
            guard !Task.isCancelled else { return }
            await self.checkEntitlementsAction(self)
        }

        startupRefreshTask = task
    }

    private func startReviewModeRefresh() {
        reviewModeRefreshTask?.cancel()
        let taskID = UUID()
        reviewModeRefreshTaskID = taskID

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.reviewModeRefreshTaskID == taskID {
                    self.reviewModeRefreshTaskID = nil
                    self.reviewModeRefreshTask = nil
                }
            }

            guard !Task.isCancelled else { return }
            await self.checkEntitlementsAction(self)
        }

        reviewModeRefreshTask = task
    }

    // MARK: - Load Products

    @discardableResult
    func requestProductLoad(
        onCompleted: @escaping @MainActor () -> Void = {}
    ) -> UUID {
        if let productLoadRequestID {
            productLoadCompletionCallbacks.append(onCompleted)
            return productLoadRequestID
        }

        let requestID = UUID()
        productLoadRequestID = requestID
        productLoadCompletionCallbacks = [onCompleted]

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.productLoadRequestID == requestID {
                    self.productLoadRequestID = nil
                    self.productLoadRequestTask = nil
                    self.productLoadCompletionCallbacks = []
                }
            }

            await self.loadProductsAction(self)
            guard !Task.isCancelled else { return }
            guard self.productLoadRequestID == requestID else { return }

            let callbacks = self.productLoadCompletionCallbacks
            callbacks.forEach { $0() }
        }

        if productLoadRequestID == requestID {
            productLoadRequestTask = task
        }
        return requestID
    }

    func waitForProductLoadRequest(_ requestID: UUID) async {
        guard productLoadRequestID == requestID else { return }
        await productLoadRequestTask?.value
    }

    func loadProducts() async {
        let maxRetries = 3
        for attempt in 0..<maxRetries {
            do {
                products = try await Product.products(for: VVTermProducts.allProducts)
                logger.info("Loaded \(self.products.count) products")
                return
            } catch {
                logger.error("Failed to load products (attempt \(attempt + 1)/\(maxRetries)): \(error.localizedDescription)")
                if attempt < maxRetries - 1 {
                    try? await Task.sleep(nanoseconds: UInt64(pow(2.0, Double(attempt))) * 1_000_000_000)
                }
            }
        }
    }

    // MARK: - Paywall Presentation

    func notePaywallPresented(source: PaywallSource) {
        activePaywallSource = source
        hasPresentedPaywallThisLaunch = true
        telemetry.notePaywallPresented(source: source)
    }

    // MARK: - Purchase

    @discardableResult
    func requestPurchase(of product: Product) -> UUID {
        requestPurchase { [weak self] in
            await self?.purchase(product)
        }
    }

    func waitForPurchaseRequest(_ requestID: UUID) async {
        await purchaseRequestTasks[requestID]?.value
    }

    @discardableResult
    fileprivate func requestPurchase(operation: @escaping @MainActor () async throws -> Void) -> UUID {
        if let purchaseRequestID {
            return purchaseRequestID
        }

        let requestID = UUID()
        purchaseRequestID = requestID
        lastPurchaseRequestFailure = nil

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.purchaseRequestID == requestID {
                    self.purchaseRequestID = nil
                }
                self.purchaseRequestTasks.removeValue(forKey: requestID)
            }

            do {
                try await operation()
            } catch is CancellationError {
                return
            } catch {
                self.lastPurchaseRequestFailure = error
            }
        }

        purchaseRequestTasks[requestID] = task
        return requestID
    }

    func purchase(_ product: Product) async {
        purchaseState = .purchasing
        lastPurchasedProductId = nil
        logger.info("Purchasing \(product.id)")

        do {
            let result = try await product.purchase()

            switch result {
            case .success(let verification):
                let transaction = try checkVerified(verification)
                await transaction.finish()
                await checkEntitlements()
                applySuccessfulPurchase(of: product)

            case .userCancelled:
                applyIdlePurchaseState(logMessage: "Purchase cancelled by user")

            case .pending:
                applyIdlePurchaseState(logMessage: "Purchase pending")

            @unknown default:
                purchaseState = .idle
            }
        } catch {
            applyPurchaseError(error)
        }
    }

    // MARK: - Restore Purchases

    @discardableResult
    func requestRestorePurchases() -> UUID {
        requestRestorePurchases { [weak self] in
            await self?.restorePurchases()
        }
    }

    func waitForRestoreRequest(_ requestID: UUID) async {
        await restoreRequestTasks[requestID]?.value
    }

    @discardableResult
    fileprivate func requestRestorePurchases(operation: @escaping @MainActor () async throws -> Void) -> UUID {
        if let restoreRequestID {
            return restoreRequestID
        }

        let requestID = UUID()
        restoreRequestID = requestID
        lastRestoreRequestFailure = nil

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.restoreRequestID == requestID {
                    self.restoreRequestID = nil
                }
                self.restoreRequestTasks.removeValue(forKey: requestID)
            }

            do {
                try await operation()
            } catch is CancellationError {
                return
            } catch {
                self.lastRestoreRequestFailure = error
            }
        }

        restoreRequestTasks[requestID] = task
        return requestID
    }

    func restorePurchases() async {
        restoreState = .restoring
        logger.info("Restoring purchases")
        do {
            try await AppStore.sync()
            await checkEntitlements()
            applyRestoreResult(hasAccess: isPro)
        } catch {
            applyRestoreError(error)
        }
    }

    // MARK: - Check Entitlements

    func checkEntitlements() async {
        refreshReviewModeState()
        let refreshGeneration = beginEntitlementRefresh()
        var hasAccess = false
        var hasLifetime = false

        for await result in Transaction.currentEntitlements {
            guard !Task.isCancelled else { return }
            if case .verified(let transaction) = result {
                switch transaction.productID {
                case VVTermProducts.proMonthly,
                     VVTermProducts.proYearly:
                    hasAccess = true
                case VVTermProducts.proLifetime:
                    hasAccess = true
                    hasLifetime = true
                default:
                    break
                }
            }
        }

        guard !Task.isCancelled else { return }

        // Check subscription status for billing retry / grace period
        var activeStatus: Product.SubscriptionInfo.Status?
        if let product = monthlyProduct ?? yearlyProduct,
           let statuses = try? await product.subscription?.status {
            activeStatus = statuses.first {
                $0.state == .subscribed || $0.state == .inGracePeriod
            } ?? statuses.first

            if !hasAccess {
                for status in statuses {
                    if case .verified = status.transaction,
                       StoreSubscriptionAccessPolicy.grantsAccess(for: status.state) {
                        hasAccess = true
                        break
                    }
                }
            }
        }

        applyEntitlementsIfCurrent(
            refreshGeneration: refreshGeneration,
            hasAccess: hasAccess,
            hasLifetime: hasLifetime,
            status: activeStatus
        )
    }

    // MARK: - Transaction Listener

    private func listenForTransactions() -> Task<Void, Never> {
        let taskID = UUID()
        updateListenerTaskID = taskID
        return Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.updateListenerTaskID == taskID {
                    self.updateListenerTaskID = nil
                    self.updateListenerTask = nil
                }
            }
            await self.transactionListenerAction(self)
        }
    }

    private func listenForLiveTransactions() async {
        for await result in Transaction.updates {
            guard !Task.isCancelled else { return }
            if case .verified(let transaction) = result {
                await checkEntitlements()
                await transaction.finish()
            }
        }
    }

    // MARK: - Verification

    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified:
            throw StoreError.verificationFailed
        case .verified(let safe):
            return safe
        }
    }

    // MARK: - Subscription Info

    var subscriptionExpirationDate: Date? {
        guard let status = subscriptionStatus else { return nil }
        guard case .verified(let transaction) = status.transaction else { return nil }
        return transaction.expirationDate
    }

    var isSubscriptionActive: Bool {
        guard let status = subscriptionStatus else { return isLifetime }
        return status.state == .subscribed || status.state == .inGracePeriod
    }

    var hasActiveSubscriptionWithLifetime: Bool {
        guard isLifetime, let status = subscriptionStatus else { return false }
        return status.state == .subscribed || status.state == .inGracePeriod
    }

    // MARK: - Review Mode

    @discardableResult
    func enableReviewMode(code: String) -> Bool {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.caseInsensitiveCompare(Self.reviewModeCode) == .orderedSame else {
            logger.warning("Review mode activation failed (invalid code)")
            return false
        }
        setReviewModeEnabled(true)
        return true
    }

    func setReviewModeEnabled(_ enabled: Bool) {
        guard isReviewModeEnabled != enabled else { return }
        isReviewModeEnabled = enabled

        if enabled {
            isPro = true
            isLifetime = false
            subscriptionStatus = nil
            reviewModeExpiresAt = Date().addingTimeInterval(reviewModeDuration)
            scheduleReviewModeExpiry()
            logger.info("Review mode enabled")
        } else {
            reviewModeExpiresAt = nil
            reviewModeExpiryTask?.cancel()
            reviewModeExpiryTask = nil
            logger.info("Review mode disabled")
            startReviewModeRefresh()
        }
    }

    func requestReviewAfterPurchase() {
        telemetry.requestReviewAfterPurchase()
    }

    func dismissRestoreResult() {
        switch restoreState {
        case .restored, .failed:
            restoreState = .idle
        case .idle, .restoring:
            break
        }
    }

    private func scheduleReviewModeExpiry() {
        reviewModeExpiryTask?.cancel()
        guard let expiresAt = reviewModeExpiresAt else { return }
        let delay = max(0, expiresAt.timeIntervalSinceNow)
        reviewModeExpiryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            await MainActor.run {
                self?.refreshReviewModeState()
            }
        }
    }

    private func refreshReviewModeState() {
        guard isReviewModeEnabled else { return }
        if let expiresAt = reviewModeExpiresAt, Date() >= expiresAt {
            setReviewModeEnabled(false)
        }
    }

    private func applySuccessfulPurchase(of product: Product) {
        lastPurchasedProductId = product.id
        purchaseState = .purchased
        telemetry.trackPurchase(source: activePaywallSource, productId: product.id)
        logger.info("Purchase successful: \(product.id)")
    }

    private func applyIdlePurchaseState(logMessage: String) {
        purchaseState = .idle
        logger.info("\(logMessage)")
    }

    private func applyPurchaseError(_ error: Error) {
        if error is CancellationError {
            applyIdlePurchaseState(logMessage: "Purchase cancelled")
            return
        }

        purchaseState = .failed(error.localizedDescription)
        logger.error("Purchase failed: \(error.localizedDescription)")
    }

    private func applyRestoreResult(hasAccess: Bool) {
        restoreState = .restored(hasAccess: hasAccess)
        logger.info("Purchases restored")
    }

    private func applyRestoreError(_ error: Error) {
        if error is CancellationError {
            restoreState = .idle
            logger.info("Restore cancelled")
            return
        }

        restoreState = .failed(error.localizedDescription)
        logger.error("Failed to restore purchases: \(error.localizedDescription)")
    }

    private func applyEntitlements(
        hasAccess: Bool,
        hasLifetime: Bool,
        status: Product.SubscriptionInfo.Status?
    ) {
        isPro = hasAccess || isReviewModeEnabled
        isLifetime = hasLifetime
        subscriptionStatus = status
        telemetry.trackAppLaunched(isPro: isPro)
        logger.info("Entitlements checked: isPro=\(hasAccess), isLifetime=\(hasLifetime), reviewMode=\(self.isReviewModeEnabled)")
    }

    private func beginEntitlementRefresh() -> Int {
        entitlementRefreshGeneration += 1
        return entitlementRefreshGeneration
    }

    private func applyEntitlementsIfCurrent(
        refreshGeneration: Int,
        hasAccess: Bool,
        hasLifetime: Bool,
        status: Product.SubscriptionInfo.Status?
    ) {
        guard refreshGeneration == entitlementRefreshGeneration else {
            logger.info("Ignored superseded entitlement refresh")
            return
        }

        applyEntitlements(hasAccess: hasAccess, hasLifetime: hasLifetime, status: status)
    }
}

#if DEBUG
extension StoreManager {
    static func makeForTesting(
        startBackgroundTasks: Bool = false,
        loadProductsAction: (@MainActor (StoreManager) async -> Void)? = nil,
        checkEntitlementsAction: (@MainActor (StoreManager) async -> Void)? = nil,
        transactionListenerAction: (@MainActor (StoreManager) async -> Void)? = nil,
        telemetry: (any StoreTelemetry)? = nil
    ) -> StoreManager {
        StoreManager(
            startBackgroundTasks: startBackgroundTasks,
            loadProductsAction: loadProductsAction,
            checkEntitlementsAction: checkEntitlementsAction,
            transactionListenerAction: transactionListenerAction,
            telemetry: telemetry ?? NoopStoreTelemetry()
        )
    }

    @discardableResult
    func requestPurchaseForTesting(
        operation: @escaping @MainActor () async throws -> Void
    ) -> UUID {
        requestPurchase(operation: operation)
    }

    @discardableResult
    func requestRestorePurchasesForTesting(
        operation: @escaping @MainActor () async throws -> Void
    ) -> UUID {
        requestRestorePurchases(operation: operation)
    }

    func applyPurchaseErrorForTesting(_ error: Error) {
        applyPurchaseError(error)
    }

    func applyRestoreErrorForTesting(_ error: Error) {
        applyRestoreError(error)
    }

    var hasPendingStartupRefreshForTesting: Bool {
        startupRefreshTask != nil
    }

    func waitForStartupRefreshForTesting() async {
        await startupRefreshTask?.value
    }

    var hasPendingReviewModeRefreshForTesting: Bool {
        reviewModeRefreshTask != nil
    }

    func waitForReviewModeRefreshForTesting() async {
        await reviewModeRefreshTask?.value
    }

    var hasPendingTransactionListenerForTesting: Bool {
        updateListenerTask != nil
    }

    func waitForTransactionListenerForTesting() async {
        await updateListenerTask?.value
    }

    func cancelTransactionListenerForTesting() {
        updateListenerTask?.cancel()
    }

    func cancelProductLoadRequestForTesting(_ requestID: UUID) {
        guard productLoadRequestID == requestID else { return }
        productLoadRequestTask?.cancel()
    }

    func applyEntitlementRefreshForTesting(
        hasAccess: Bool,
        hasLifetime: Bool,
        beforeApply: @escaping @MainActor () async -> Void
    ) async {
        let refreshGeneration = beginEntitlementRefresh()
        await beforeApply()
        applyEntitlementsIfCurrent(
            refreshGeneration: refreshGeneration,
            hasAccess: hasAccess,
            hasLifetime: hasLifetime,
            status: nil
        )
    }
}
#endif
