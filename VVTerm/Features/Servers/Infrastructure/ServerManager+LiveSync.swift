import Foundation

extension CloudKitManager: ServerCloudSyncing {
    func isSchemaError(_ error: Error) -> Bool {
        Self.isSchemaError(error)
    }
}

extension CloudKitSyncCoordinator: ServerPendingCloudSyncCoordinating {}

extension ServerManager {
    static let shared = ServerManager()

    convenience init() {
        self.init(
            cloudKit: CloudKitManager.shared,
            syncCoordinator: CloudKitSyncCoordinator.shared,
            localDataStore: UserDefaultsServerLocalDataStore(),
            isProProvider: { StoreManager.shared.isPro }
        )
    }
}
