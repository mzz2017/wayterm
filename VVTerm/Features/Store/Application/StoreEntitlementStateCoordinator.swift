import StoreKit

struct StoreEntitlementSnapshot {
    let hasAccess: Bool
    let hasLifetime: Bool
    let status: Product.SubscriptionInfo.Status?
}

struct StoreEntitlementPublishedState: Equatable {
    let isPro: Bool
    let isLifetime: Bool
    let status: Product.SubscriptionInfo.Status?
    let hasStoreAccess: Bool
}

struct StoreEntitlementStateCoordinator {
    private var generationGate = StoreEntitlementRefreshGenerationGate()

    mutating func beginRefresh() -> StoreEntitlementRefreshGenerationGate.Token {
        generationGate.beginRefresh()
    }

    func isCurrent(_ token: StoreEntitlementRefreshGenerationGate.Token) -> Bool {
        generationGate.isCurrent(token)
    }

    func publishIfCurrent(
        _ token: StoreEntitlementRefreshGenerationGate.Token,
        snapshot: StoreEntitlementSnapshot,
        isReviewModeEnabled: Bool
    ) -> StoreEntitlementPublishedState? {
        guard isCurrent(token) else { return nil }
        return StoreEntitlementPublishedState(
            isPro: snapshot.hasAccess || isReviewModeEnabled,
            isLifetime: snapshot.hasLifetime,
            status: snapshot.status,
            hasStoreAccess: snapshot.hasAccess
        )
    }
}
