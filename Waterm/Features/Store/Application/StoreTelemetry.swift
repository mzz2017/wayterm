import Foundation

@MainActor
protocol StoreTelemetry {
    func notePaywallPresented(source: PaywallSource)
    func trackPurchase(source: PaywallSource, productId: String)
    func trackAppLaunched(isPro: Bool)
    func requestReviewAfterPurchase()
}

@MainActor
struct LiveStoreTelemetry: StoreTelemetry {
    static let shared = LiveStoreTelemetry(
        analytics: .shared,
        engagement: .shared
    )

    private let analytics: AnalyticsTracker
    private let engagement: EngagementTracker

    init(
        analytics: AnalyticsTracker,
        engagement: EngagementTracker
    ) {
        self.analytics = analytics
        self.engagement = engagement
    }

    func notePaywallPresented(source: PaywallSource) {
        engagement.notePaywallPresented()
        if source == .postFirstConnection {
            engagement.markProIntroShown()
        }
        analytics.trackPaywallViewed(source: source.rawValue)
    }

    func trackPurchase(source: PaywallSource, productId: String) {
        analytics.trackPurchase(source: source.rawValue, productId: productId)
    }

    func trackAppLaunched(isPro: Bool) {
        analytics.trackAppLaunched(isPro: isPro)
    }

    func requestReviewAfterPurchase() {
        engagement.requestReviewAfterPurchase()
    }
}

@MainActor
struct NoopStoreTelemetry: StoreTelemetry {
    func notePaywallPresented(source: PaywallSource) {}
    func trackPurchase(source: PaywallSource, productId: String) {}
    func trackAppLaunched(isPro: Bool) {}
    func requestReviewAfterPurchase() {}
}
