import Combine
import Foundation

struct SyncSettingsCloudStatusSnapshot: Equatable {
    let syncStatus: CloudKitManager.SyncStatus
    let lastSyncDate: Date?
    let isAvailable: Bool
    let accountStatusDetail: String
}

@MainActor
protocol SyncSettingsCloudStatusProviding: AnyObject {
    var currentStatusSnapshot: SyncSettingsCloudStatusSnapshot { get }
    var statusSnapshots: AnyPublisher<SyncSettingsCloudStatusSnapshot, Never> { get }
}

extension CloudKitManager: SyncSettingsCloudStatusProviding {
    var currentStatusSnapshot: SyncSettingsCloudStatusSnapshot {
        SyncSettingsCloudStatusSnapshot(
            syncStatus: syncStatus,
            lastSyncDate: lastSyncDate,
            isAvailable: isAvailable,
            accountStatusDetail: accountStatusDetail
        )
    }

    var statusSnapshots: AnyPublisher<SyncSettingsCloudStatusSnapshot, Never> {
        Publishers.CombineLatest4($syncStatus, $lastSyncDate, $isAvailable, $accountStatusDetail)
            .map { syncStatus, lastSyncDate, isAvailable, accountStatusDetail in
                SyncSettingsCloudStatusSnapshot(
                    syncStatus: syncStatus,
                    lastSyncDate: lastSyncDate,
                    isAvailable: isAvailable,
                    accountStatusDetail: accountStatusDetail
                )
            }
            .eraseToAnyPublisher()
    }
}

@MainActor
protocol SyncSettingsCoordinating: AnyObject {
    func handleSyncSettingsChanged(_ enabled: Bool) -> Task<Void, Never>
    func refreshCloudKitStatusFromSettings() -> Task<Void, Never>
}

extension AppSyncCoordinator: SyncSettingsCoordinating {}

@MainActor
final class SyncSettingsStore: ObservableObject {
    static let shared = SyncSettingsStore()

    @Published private(set) var syncStatus: CloudKitManager.SyncStatus
    @Published private(set) var lastSyncDate: Date?
    @Published private(set) var isAvailable: Bool
    @Published private(set) var accountStatusDetail: String

    private let statusProvider: any SyncSettingsCloudStatusProviding
    private let coordinator: any SyncSettingsCoordinating
    private var statusCancellable: AnyCancellable?
    private var syncSettingsChangeTasks: [UUID: Task<Void, Never>] = [:]
    private var cloudKitStatusRefreshTask: (id: UUID, task: Task<Void, Never>)?

    var pendingSyncSettingsChangeIDs: Set<UUID> {
        Set(syncSettingsChangeTasks.keys)
    }

    var pendingCloudKitStatusRefreshID: UUID? {
        cloudKitStatusRefreshTask?.id
    }

    init(
        statusProvider: any SyncSettingsCloudStatusProviding = CloudKitManager.shared,
        coordinator: any SyncSettingsCoordinating = AppSyncCoordinator.shared
    ) {
        self.statusProvider = statusProvider
        self.coordinator = coordinator
        let snapshot = statusProvider.currentStatusSnapshot
        syncStatus = snapshot.syncStatus
        lastSyncDate = snapshot.lastSyncDate
        isAvailable = snapshot.isAvailable
        accountStatusDetail = snapshot.accountStatusDetail

        statusCancellable = statusProvider.statusSnapshots
            .sink { [weak self] snapshot in
                self?.apply(snapshot)
            }
    }

    deinit {
        for task in syncSettingsChangeTasks.values {
            task.cancel()
        }
        cloudKitStatusRefreshTask?.task.cancel()
    }

    @discardableResult
    func handleSyncEnabledChanged(_ enabled: Bool) -> UUID {
        let requestID = UUID()
        let coordinatorTask = coordinator.handleSyncSettingsChanged(enabled)
        let task = Task { [weak self] in
            await coordinatorTask.value
            self?.clearSyncSettingsChangeTask(id: requestID)
        }
        syncSettingsChangeTasks[requestID] = task
        return requestID
    }

    func waitForSyncSettingsChange(_ requestID: UUID) async {
        await syncSettingsChangeTasks[requestID]?.value
    }

    @discardableResult
    func refreshCloudKitStatus() -> UUID {
        if let cloudKitStatusRefreshTask {
            return cloudKitStatusRefreshTask.id
        }

        let requestID = UUID()
        let coordinatorTask = coordinator.refreshCloudKitStatusFromSettings()
        let task = Task { [weak self] in
            await coordinatorTask.value
            self?.clearCloudKitStatusRefreshTask(id: requestID)
        }
        cloudKitStatusRefreshTask = (requestID, task)
        return requestID
    }

    func waitForCloudKitStatusRefresh(_ requestID: UUID) async {
        guard cloudKitStatusRefreshTask?.id == requestID else { return }
        await cloudKitStatusRefreshTask?.task.value
    }

    private func apply(_ snapshot: SyncSettingsCloudStatusSnapshot) {
        syncStatus = snapshot.syncStatus
        lastSyncDate = snapshot.lastSyncDate
        isAvailable = snapshot.isAvailable
        accountStatusDetail = snapshot.accountStatusDetail
    }

    private func clearSyncSettingsChangeTask(id: UUID) {
        syncSettingsChangeTasks.removeValue(forKey: id)
    }

    private func clearCloudKitStatusRefreshTask(id: UUID) {
        guard cloudKitStatusRefreshTask?.id == id else { return }
        cloudKitStatusRefreshTask = nil
    }
}
