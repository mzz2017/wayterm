import StoreKit
import Foundation
import Combine
import os.log

// MARK: - Store Manager

nonisolated enum StoreEntitlementRefreshReason: Sendable {
    case foreground
    case subscriptionExpiration
}

@MainActor
final class StoreManager: ObservableObject {
    private typealias StoreLifecycleAction = @MainActor (StoreManager) async -> Void
    private typealias StoreTransactionListenerAction = @MainActor (StoreManager) async -> Void
    private typealias StoreEntitlementRefreshSleepAction = @Sendable (Duration) async -> Void

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
    private let purchaseRequestCoordinator = StoreRequestLifecycleCoordinator()
    private let restoreRequestCoordinator = StoreRequestLifecycleCoordinator()
    private let entitlementRefreshCoordinator = StoreEntitlementRefreshCoordinator()
    private let productLoadCoordinator = StoreProductLoadCoordinator()
    var lastPurchaseRequestFailure: Error? { purchaseRequestCoordinator.lastRequestFailure }
    var lastRestoreRequestFailure: Error? { restoreRequestCoordinator.lastRequestFailure }
    var pendingPurchaseRequestIDs: Set<UUID> { purchaseRequestCoordinator.pendingRequestIDs }
    var pendingRestoreRequestIDs: Set<UUID> { restoreRequestCoordinator.pendingRequestIDs }
    var pendingProductLoadRequestIDs: Set<UUID> {
        productLoadCoordinator.pendingRequestIDs
    }
    var pendingEntitlementRefreshRequestIDs: Set<UUID> {
        entitlementRefreshCoordinator.pendingRequestIDs
    }

    private var startupRefreshTask: Task<Void, Never>?
    private var startupRefreshTaskID: UUID?
    private var reviewModeRefreshTask: Task<Void, Never>?
    private var reviewModeRefreshTaskID: UUID?
    private var subscriptionExpirationRefreshTask: Task<Void, Never>?
    private var subscriptionExpirationRefreshTaskID: UUID?
    private var updateListenerTask: Task<Void, Never>?
    private var updateListenerTaskID: UUID?
    private var reviewModeExpiryTask: Task<Void, Never>?
    private var reviewModeExpiresAt: Date?
    private var entitlementRefreshGeneration = 0
    private let loadProductsAction: StoreLifecycleAction
    private let checkEntitlementsAction: StoreLifecycleAction
    private let transactionListenerAction: StoreTransactionListenerAction
    private let sleepForEntitlementRefresh: StoreEntitlementRefreshSleepAction
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
        sleepForEntitlementRefresh: StoreEntitlementRefreshSleepAction? = nil,
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
        self.sleepForEntitlementRefresh = sleepForEntitlementRefresh ?? { duration in
            try? await Task.sleep(for: duration)
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
        entitlementRefreshCoordinator.cancelAllFromAnyContext()
        subscriptionExpirationRefreshTask?.cancel()
        reviewModeExpiryTask?.cancel()
        productLoadCoordinator.cancelAllFromAnyContext()
        purchaseRequestCoordinator.cancelAllFromAnyContext()
        restoreRequestCoordinator.cancelAllFromAnyContext()
    }

    func cancelAllAndWait() async {
        let trackedTasks = [
            updateListenerTask,
            startupRefreshTask,
            reviewModeRefreshTask,
            subscriptionExpirationRefreshTask,
            reviewModeExpiryTask
        ].compactMap { $0 }

        trackedTasks.forEach { $0.cancel() }
        await productLoadCoordinator.cancelAllAndWait()
        await purchaseRequestCoordinator.cancelAllAndWait()
        await restoreRequestCoordinator.cancelAllAndWait()
        await entitlementRefreshCoordinator.cancelAllAndWait()
        for task in trackedTasks {
            await task.value
        }

        updateListenerTask = nil
        updateListenerTaskID = nil
        startupRefreshTask = nil
        startupRefreshTaskID = nil
        reviewModeRefreshTask = nil
        reviewModeRefreshTaskID = nil
        subscriptionExpirationRefreshTask = nil
        subscriptionExpirationRefreshTaskID = nil
        reviewModeExpiryTask = nil
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
        productLoadCoordinator.requestLoad(onCompleted: onCompleted) { [weak self] in
            guard let self else { return }
            await self.loadProductsAction(self)
        }
    }

    func waitForProductLoadRequest(_ requestID: UUID) async {
        await productLoadCoordinator.waitForLoad(requestID)
    }

    @discardableResult
    func requestEntitlementRefresh(reason: StoreEntitlementRefreshReason) -> UUID {
        entitlementRefreshCoordinator.requestRefresh(reason: reason) { [weak self] in
            guard let self else { return }
            await self.checkEntitlementsAction(self)
        }
    }

    func waitForEntitlementRefreshRequest(_ requestID: UUID) async {
        await entitlementRefreshCoordinator.waitForRefresh(requestID)
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
        await purchaseRequestCoordinator.waitForRequest(requestID)
    }

    @discardableResult
    fileprivate func requestPurchase(operation: @escaping @MainActor () async throws -> Void) -> UUID {
        purchaseRequestCoordinator.request(operation: operation)
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
        await restoreRequestCoordinator.waitForRequest(requestID)
    }

    @discardableResult
    fileprivate func requestRestorePurchases(operation: @escaping @MainActor () async throws -> Void) -> UUID {
        restoreRequestCoordinator.request(operation: operation)
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
        updateSubscriptionExpirationRefresh(
            hasAccess: hasAccess,
            hasLifetime: hasLifetime,
            expirationDate: subscriptionExpirationDate(from: status)
        )
        telemetry.trackAppLaunched(isPro: isPro)
        logger.info("Entitlements checked: isPro=\(hasAccess), isLifetime=\(hasLifetime), reviewMode=\(self.isReviewModeEnabled)")
    }

    private func updateSubscriptionExpirationRefresh(
        hasAccess: Bool,
        hasLifetime: Bool,
        expirationDate: Date?
    ) {
        subscriptionExpirationRefreshTask?.cancel()
        subscriptionExpirationRefreshTask = nil
        subscriptionExpirationRefreshTaskID = nil

        guard hasAccess, !hasLifetime, let expirationDate else { return }
        scheduleSubscriptionExpirationRefresh(at: expirationDate)
    }

    private func scheduleSubscriptionExpirationRefresh(at expirationDate: Date) {
        subscriptionExpirationRefreshTask?.cancel()

        let taskID = UUID()
        subscriptionExpirationRefreshTaskID = taskID
        let sleepForEntitlementRefresh = sleepForEntitlementRefresh
        let delay = max(0, expirationDate.timeIntervalSinceNow)
        let delayNanoseconds = Int64(delay * 1_000_000_000)
        let task = Task { @MainActor [weak self] in
            await sleepForEntitlementRefresh(.nanoseconds(delayNanoseconds))
            guard !Task.isCancelled else { return }
            guard let self, self.subscriptionExpirationRefreshTaskID == taskID else { return }

            let requestID = self.requestEntitlementRefresh(reason: .subscriptionExpiration)
            await self.waitForEntitlementRefreshRequest(requestID)

            if self.subscriptionExpirationRefreshTaskID == taskID {
                self.subscriptionExpirationRefreshTaskID = nil
                self.subscriptionExpirationRefreshTask = nil
            }
        }

        subscriptionExpirationRefreshTask = task
    }

    private func subscriptionExpirationDate(from status: Product.SubscriptionInfo.Status?) -> Date? {
        guard let status else { return nil }
        guard case .verified(let transaction) = status.transaction else { return nil }
        return transaction.expirationDate
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
        sleepForEntitlementRefresh: (@Sendable (Duration) async -> Void)? = nil,
        telemetry: (any StoreTelemetry)? = nil
    ) -> StoreManager {
        StoreManager(
            startBackgroundTasks: startBackgroundTasks,
            loadProductsAction: loadProductsAction,
            checkEntitlementsAction: checkEntitlementsAction,
            transactionListenerAction: transactionListenerAction,
            sleepForEntitlementRefresh: sleepForEntitlementRefresh,
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
        productLoadCoordinator.cancelRequest(requestID)
    }

    func cancelPurchaseRequestForTesting(_ requestID: UUID) {
        purchaseRequestCoordinator.cancelRequest(requestID)
    }

    func cancelRestoreRequestForTesting(_ requestID: UUID) {
        restoreRequestCoordinator.cancelRequest(requestID)
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

    var hasPendingSubscriptionExpirationRefreshForTesting: Bool {
        subscriptionExpirationRefreshTask != nil
    }

    func waitForSubscriptionExpirationRefreshForTesting() async {
        await subscriptionExpirationRefreshTask?.value
    }

    func scheduleSubscriptionExpirationRefreshForTesting(at expirationDate: Date) {
        scheduleSubscriptionExpirationRefresh(at: expirationDate)
    }
}
#endif
