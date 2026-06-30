import StoreKit

nonisolated enum StoreSubscriptionAccessPolicy {
    static func grantsAccess(for state: Product.SubscriptionInfo.RenewalState) -> Bool {
        switch state {
        case .subscribed, .inGracePeriod:
            return true
        case .expired, .inBillingRetryPeriod, .revoked:
            return false
        default:
            return false
        }
    }
}
