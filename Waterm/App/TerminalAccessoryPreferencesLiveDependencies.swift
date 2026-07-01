import Foundation

extension TerminalAccessoryPreferencesDependencies {
    @MainActor
    static var live: TerminalAccessoryPreferencesDependencies {
        TerminalAccessoryPreferencesDependencies(
            isPro: { StoreManager.shared.isPro },
            trackCustomActionCreated: { kind in
                AnalyticsTracker.shared.trackCustomActionCreated(kind: kind.rawValue)
            },
            cloudProfileSync: TerminalAccessoryCloudKitProfileSyncService(cloudKit: CloudKitManager.shared),
            syncCoordinator: CloudKitSyncCoordinator.shared
        )
    }
}
