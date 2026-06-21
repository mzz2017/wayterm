import Combine
import Foundation
import Testing
@testable import VVTerm

// Test Context:
// These tests protect the Settings application boundary for iCloud sync status
// and sync-settings intent. SyncSettingsView may render CloudKit status and send
// toggle/recheck intent, but it must not observe CloudKitManager or invoke
// AppSyncCoordinator directly. The fake status provider publishes explicit
// changes so failures distinguish broken state bridging from CloudKit account
// behavior. The fake coordinator returns held tasks so failures distinguish
// dropped/duplicated lifecycle tracking from real CloudKit sync work. Update
// this context only when sync-settings ownership intentionally moves to another
// application-layer owner or the settings recheck/toggle workflow changes.
@Suite(.serialized)
@MainActor
struct SyncSettingsStoreTests {
    @Test
    func snapshotsInitialCloudKitStatus() {
        // Given CloudKit already has a known unavailable status before the
        // Settings screen observes it.
        let lastSyncDate = Date(timeIntervalSince1970: 1_800_000_000)
        let statusProvider = FakeSyncSettingsCloudStatusProvider(
            syncStatus: .offline,
            lastSyncDate: lastSyncDate,
            isAvailable: false,
            accountStatusDetail: "noAccount - User not signed into iCloud"
        )
        let coordinator = FakeSyncSettingsCoordinator()

        // When the Settings application store is created.
        let store = SyncSettingsStore(
            statusProvider: statusProvider,
            coordinator: coordinator
        )

        // Then the SwiftUI layer can render a complete value snapshot without
        // observing CloudKitManager directly.
        #expect(store.syncStatus == .offline)
        #expect(store.lastSyncDate == lastSyncDate)
        #expect(store.isAvailable == false)
        #expect(store.accountStatusDetail == "noAccount - User not signed into iCloud")
    }

    @Test
    func updatesPublishedCloudKitStatusSnapshot() {
        // Given the Settings store is observing CloudKit status through the
        // application boundary.
        let statusProvider = FakeSyncSettingsCloudStatusProvider()
        let coordinator = FakeSyncSettingsCoordinator()
        let store = SyncSettingsStore(
            statusProvider: statusProvider,
            coordinator: coordinator
        )

        // When the status provider publishes a new account/sync status.
        let lastSyncDate = Date(timeIntervalSince1970: 1_800_000_100)
        statusProvider.publish(
            syncStatus: .error("network unavailable"),
            lastSyncDate: lastSyncDate,
            isAvailable: false,
            accountStatusDetail: "temporarilyUnavailable"
        )

        // Then the application store updates the rendered snapshot, keeping
        // SwiftUI as a pure consumer of application-owned state.
        #expect(store.syncStatus == .error("network unavailable"))
        #expect(store.lastSyncDate == lastSyncDate)
        #expect(store.isAvailable == false)
        #expect(store.accountStatusDetail == "temporarilyUnavailable")
    }

    @Test
    func publishedStatusSnapshotDoesNotDependOnPostPublishPropertyReads() {
        // Given the Settings store observes a provider whose publisher fires
        // before its backing properties are updated, matching the ordering risk
        // at @Published boundaries.
        let statusProvider = FakeSyncSettingsCloudStatusProvider()
        let coordinator = FakeSyncSettingsCoordinator()
        let store = SyncSettingsStore(
            statusProvider: statusProvider,
            coordinator: coordinator
        )

        // When the provider announces the new snapshot before mutating its
        // readable properties.
        statusProvider.publishBeforeApplyingProperties(
            syncStatus: .error("account unavailable"),
            lastSyncDate: nil,
            isAvailable: false,
            accountStatusDetail: "noAccount"
        )

        // Then the store still renders the announced snapshot instead of
        // lagging behind by re-reading stale provider properties.
        #expect(store.syncStatus == .error("account unavailable"))
        #expect(store.lastSyncDate == nil)
        #expect(store.isAvailable == false)
        #expect(store.accountStatusDetail == "noAccount")
    }

    @Test
    func syncToggleIntentDelegatesToCoordinatorAsTrackedTask() async {
        // Given Settings needs to disable iCloud sync.
        let statusProvider = FakeSyncSettingsCloudStatusProvider()
        let coordinator = FakeSyncSettingsCoordinator()
        let store = SyncSettingsStore(
            statusProvider: statusProvider,
            coordinator: coordinator
        )

        // When the UI sends sync-toggle intent to the store.
        let requestID = store.handleSyncEnabledChanged(false)
        await store.waitForSyncSettingsChange(requestID)

        // Then the store delegates to the app-level coordinator and keeps the
        // returned lifecycle task awaitable for tests and later operations.
        #expect(coordinator.toggleRequests == [false])
        #expect(
            store.pendingSyncSettingsChangeIDs.isEmpty,
            "Completed sync-toggle tasks should be cleared from the Settings application store."
        )
    }

    @Test
    func cloudKitStatusRefreshReusesPendingCoordinatorTask() async {
        // Given CloudKit status recheck is still running.
        let statusProvider = FakeSyncSettingsCloudStatusProvider()
        let coordinator = FakeSyncSettingsCoordinator()
        let releaseRefresh = AsyncGate()
        coordinator.refreshTaskFactory = {
            Task {
                await releaseRefresh.wait()
            }
        }
        let store = SyncSettingsStore(
            statusProvider: statusProvider,
            coordinator: coordinator
        )

        // When Settings asks to re-check iCloud status twice before the first
        // request has completed.
        let firstID = store.refreshCloudKitStatus()
        let secondID = store.refreshCloudKitStatus()

        // Then the second intent waits on the already tracked task instead of
        // creating duplicate app-sync recheck work.
        #expect(firstID == secondID)
        #expect(coordinator.refreshRequestCount == 1)
        await releaseRefresh.open()
        await store.waitForCloudKitStatusRefresh(firstID)
        #expect(
            store.pendingCloudKitStatusRefreshID == nil,
            "Completed CloudKit status refresh tasks should clear from the Settings application store."
        )
    }
}

@MainActor
private final class FakeSyncSettingsCloudStatusProvider: SyncSettingsCloudStatusProviding {
    var syncStatus: CloudKitManager.SyncStatus
    var lastSyncDate: Date?
    var isAvailable: Bool
    var accountStatusDetail: String

    var currentStatusSnapshot: SyncSettingsCloudStatusSnapshot {
        SyncSettingsCloudStatusSnapshot(
            syncStatus: syncStatus,
            lastSyncDate: lastSyncDate,
            isAvailable: isAvailable,
            accountStatusDetail: accountStatusDetail
        )
    }

    var statusSnapshots: AnyPublisher<SyncSettingsCloudStatusSnapshot, Never> {
        statusSubject.eraseToAnyPublisher()
    }

    private let statusSubject = PassthroughSubject<SyncSettingsCloudStatusSnapshot, Never>()

    init(
        syncStatus: CloudKitManager.SyncStatus = .idle,
        lastSyncDate: Date? = nil,
        isAvailable: Bool = true,
        accountStatusDetail: String = "available"
    ) {
        self.syncStatus = syncStatus
        self.lastSyncDate = lastSyncDate
        self.isAvailable = isAvailable
        self.accountStatusDetail = accountStatusDetail
    }

    func publish(
        syncStatus: CloudKitManager.SyncStatus,
        lastSyncDate: Date?,
        isAvailable: Bool,
        accountStatusDetail: String
    ) {
        self.syncStatus = syncStatus
        self.lastSyncDate = lastSyncDate
        self.isAvailable = isAvailable
        self.accountStatusDetail = accountStatusDetail
        statusSubject.send(currentStatusSnapshot)
    }

    func publishBeforeApplyingProperties(
        syncStatus: CloudKitManager.SyncStatus,
        lastSyncDate: Date?,
        isAvailable: Bool,
        accountStatusDetail: String
    ) {
        let snapshot = SyncSettingsCloudStatusSnapshot(
            syncStatus: syncStatus,
            lastSyncDate: lastSyncDate,
            isAvailable: isAvailable,
            accountStatusDetail: accountStatusDetail
        )
        statusSubject.send(snapshot)
        self.syncStatus = syncStatus
        self.lastSyncDate = lastSyncDate
        self.isAvailable = isAvailable
        self.accountStatusDetail = accountStatusDetail
    }
}

@MainActor
private final class FakeSyncSettingsCoordinator: SyncSettingsCoordinating {
    var toggleRequests: [Bool] = []
    var refreshRequestCount = 0
    var refreshTaskFactory: () -> Task<Void, Never> = {
        Task {}
    }

    func handleSyncSettingsChanged(_ enabled: Bool) -> Task<Void, Never> {
        toggleRequests.append(enabled)
        return Task {}
    }

    func refreshCloudKitStatusFromSettings() -> Task<Void, Never> {
        refreshRequestCount += 1
        return refreshTaskFactory()
    }
}

private actor AsyncGate {
    private var isOpen = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func open() {
        isOpen = true
        let ready = continuations
        continuations.removeAll()
        for continuation in ready {
            continuation.resume()
        }
    }

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }
}
