import CloudKit
import Foundation
import Combine
import os.log

// MARK: - CloudKit Manager

struct CloudKitRecordChanges {
    let records: [CKRecord]
    let deletions: [CloudKitManager.Deletion]
    let isFullFetch: Bool
    let changeToken: CKServerChangeToken?
}

@MainActor
final class CloudKitManager: ObservableObject {
    static let shared = CloudKitManager()

    @Published var syncStatus: SyncStatus = .idle
    @Published var lastSyncDate: Date?
    @Published var isAvailable: Bool = false
    @Published var accountStatusDetail: String = String(localized: "Checking...")

    private let container: CKContainer
    let database: CKDatabase
    let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "CloudKit")
    private let recordZoneName = CloudKitSyncConstants.recordZoneName
    lazy var recordZone = CKRecordZone(zoneName: recordZoneName)
    var recordZoneID: CKRecordZone.ID { recordZone.zoneID }
    var changeTokenKey: String { CloudKitSyncConstants.changeTokenKey(for: recordZoneName) }
    var zoneReadyKey: String { CloudKitSyncConstants.zoneReadyKey(for: recordZoneName) }

    enum SyncStatus: Equatable {
        case idle
        case syncing
        case error(String)
        case offline
        case disabled

        var description: String {
            switch self {
            case .idle: return String(localized: "Synced")
            case .syncing: return String(localized: "Syncing...")
            case .error(let message): return String(format: String(localized: "Error: %@"), message)
            case .offline: return String(localized: "Offline")
            case .disabled: return String(localized: "Disabled")
            }
        }
    }

    private var accountStatusChecked = false
    private var isSyncEnabled: Bool { SyncSettings.isEnabled }
    private var accountStatusRefreshTask: (id: UUID, task: Task<Void, Never>)?
    private var fetchChangesTask: Task<CloudKitRecordChanges, Error>?
    var ensureZoneTask: Task<Void, Error>?
    var zoneReady: Bool

    private init() {
        container = CKContainer(identifier: CloudKitSyncConstants.cloudKitContainerIdentifier)
        database = container.privateCloudDatabase
        zoneReady = UserDefaults.standard.bool(forKey: CloudKitSyncConstants.zoneReadyKey(for: recordZoneName))
        _ = requestAccountStatusRefresh()
    }

    // MARK: - Account Status

    /// Ensures account status is checked before performing operations
    private func ensureAccountStatusChecked() async {
        guard isSyncEnabled else {
            applySyncDisabledState()
            accountStatusChecked = true
            return
        }
        // Re-check when unavailable so transient account/network states can recover
        guard !accountStatusChecked || !isAvailable else { return }
        await requestAccountStatusRefresh().value
    }

    @discardableResult
    private func requestAccountStatusRefresh() -> Task<Void, Never> {
        if let accountStatusRefreshTask {
            return accountStatusRefreshTask.task
        }

        let taskID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.checkAccountStatus()
            self.clearAccountStatusRefreshTask(id: taskID)
        }
        accountStatusRefreshTask = (taskID, task)
        return task
    }

    private func clearAccountStatusRefreshTask(id: UUID) {
        guard accountStatusRefreshTask?.id == id else { return }
        accountStatusRefreshTask = nil
    }

    private func checkAccountStatus() async {
        guard isSyncEnabled else {
            applySyncDisabledState()
            accountStatusChecked = true
            return
        }

        do {
            let status = try await container.accountStatus()
            guard isSyncEnabled else {
                applySyncDisabledState()
                accountStatusChecked = true
                return
            }
            let statusDescription: String
            switch status {
            case .available:
                statusDescription = String(localized: "available")
            case .noAccount:
                statusDescription = String(localized: "noAccount - User not signed into iCloud")
            case .restricted:
                statusDescription = String(localized: "restricted - iCloud access restricted (parental controls, MDM, etc.)")
            case .couldNotDetermine:
                statusDescription = String(localized: "couldNotDetermine - Unable to determine iCloud status")
            case .temporarilyUnavailable:
                statusDescription = String(localized: "temporarilyUnavailable - iCloud temporarily unavailable")
            @unknown default:
                statusDescription = String(format: String(localized: "unknown status: %@"), String(status.rawValue))
            }

            logger.info("CloudKit account status: \(statusDescription)")
            logger.info("Container identifier: \(self.container.containerIdentifier ?? "nil")")

            isAvailable = status == .available
            accountStatusDetail = statusDescription
            accountStatusChecked = true
            if isAvailable {
                if case .offline = syncStatus {
                    syncStatus = .idle
                }
            } else {
                syncStatus = .offline
                logger.warning("CloudKit not available. Status: \(statusDescription)")
            }
        } catch {
            logger.error("CloudKit account status check failed: \(error.localizedDescription)")
            isAvailable = false
            accountStatusDetail = String(format: String(localized: "Error: %@"), error.localizedDescription)
            syncStatus = .error(error.localizedDescription)
            accountStatusChecked = true
        }
    }

    private func applySyncDisabledState() {
        isAvailable = false
        syncStatus = .disabled
        accountStatusDetail = String(localized: "Disabled")
    }

    func handleSyncToggle(_ enabled: Bool) async {
        if enabled {
            accountStatusChecked = false
            await requestAccountStatusRefresh().value
            guard !Task.isCancelled else { return }
            await subscribeToChanges()
        } else {
            applySyncDisabledState()
        }
    }

    // MARK: - Change Fetching (Incremental, No Queries)

    func fetchRecordChanges(forceFullFetch: Bool = false) async throws -> CloudKitRecordChanges {
        await ensureAccountStatusChecked()
        guard isAvailable else {
            throw CloudKitError.notAvailable
        }

        try await ensureCustomZone()

        if !forceFullFetch, let task = fetchChangesTask {
            return try await task.value
        }

        let task = Task { try await self.withZoneRetry { try await self.fetchRecordChangesFromCloudKit(forceFullFetch: forceFullFetch) } }
        if !forceFullFetch {
            fetchChangesTask = task
        }
        defer {
            if !forceFullFetch {
                fetchChangesTask = nil
            }
        }

        return try await task.value
    }

    private func fetchRecordChangesFromCloudKit(forceFullFetch: Bool) async throws -> CloudKitRecordChanges {
        syncStatus = .syncing
        defer { syncStatus = .idle }

        let previousToken = forceFullFetch ? nil : loadChangeToken()

        do {
            let changes = try await fetchRecordChangesFromCloudKit(
                previousToken: previousToken,
                isFullFetch: forceFullFetch || previousToken == nil
            )
            lastSyncDate = Date()
            logger.info(
                "Fetched \(changes.records.count) CloudKit records and \(changes.deletions.count) deletions (full fetch: \(changes.isFullFetch))"
            )
            return changes
        } catch {
            if isChangeTokenExpired(error) {
                logger.warning("CloudKit change token expired; resetting and performing full fetch")
                clearChangeToken()
                let changes = try await fetchRecordChangesFromCloudKit(previousToken: nil, isFullFetch: true)
                lastSyncDate = Date()
                return changes
            }

            logger.error("Failed to fetch changes: \(error.localizedDescription)")
            syncStatus = .error(error.localizedDescription)
            throw error
        }
    }

    private func fetchRecordChangesFromCloudKit(
        previousToken: CKServerChangeToken?,
        isFullFetch: Bool
    ) async throws -> CloudKitRecordChanges {
        let zoneID = recordZoneID
        var token = previousToken
        var moreComing = true

        var records: [CKRecord] = []
        var deletions: [Deletion] = []

        while moreComing {
            let batch = try await fetchZoneChanges(zoneID: zoneID, previousToken: token)
            records.append(contentsOf: batch.records)
            deletions.append(contentsOf: batch.deletions)
            token = batch.serverChangeToken
            moreComing = batch.moreComing
        }

        return CloudKitRecordChanges(
            records: records,
            deletions: deletions,
            isFullFetch: isFullFetch,
            changeToken: token
        )
    }

    func commitChangeToken(_ token: CKServerChangeToken?) {
        guard let token else { return }
        saveChangeToken(token)
    }

    // MARK: - Record Operations

    func fetchRecords(matchingRecordTypes recordTypes: Set<String>) async throws -> [CKRecord] {
        await ensureAccountStatusChecked()
        guard isAvailable else {
            throw CloudKitError.notAvailable
        }

        try await ensureCustomZone()
        return try await withZoneRetry {
            try await fetchAllRecordsFromCloudKit(matchingRecordTypes: recordTypes)
        }
    }

    func fetchRecord(named recordName: String) async throws -> CKRecord? {
        await ensureAccountStatusChecked()
        guard isAvailable else {
            throw CloudKitError.notAvailable
        }

        try await ensureCustomZone()
        let recordID = CKRecord.ID(recordName: recordName, zoneID: recordZoneID)

        do {
            return try await withZoneRetry {
                try await database.record(for: recordID)
            }
        } catch let ckError as CKError where ckError.code == .unknownItem || ckError.code == .zoneNotFound {
            return nil
        } catch {
            throw error
        }
    }

    func saveCloudKitRecord(
        _ record: CKRecord,
        successLog: String,
        failureLog: String,
        savePolicy: CKModifyRecordsOperation.RecordSavePolicy = .changedKeys
    ) async throws {
        try await prepareSyncMutation()
        try await performSyncMutation(
            successLog: successLog,
            failureLog: failureLog
        ) {
            try await withZoneRetry {
                try await saveRecord(record, savePolicy: savePolicy)
            }
        }
    }

    func deleteCloudKitRecord(
        named recordName: String,
        successLog: String,
        failureLog: String
    ) async throws {
        try await prepareSyncMutation()
        let recordID = CKRecord.ID(recordName: recordName, zoneID: recordZoneID)
        _ = try await performSyncMutation(
            successLog: successLog,
            failureLog: failureLog
        ) {
            _ = try await withZoneRetry {
                try await database.modifyRecords(saving: [], deleting: [recordID])
            }
        }
    }

    private func prepareSyncMutation() async throws {
        await ensureAccountStatusChecked()
        guard isAvailable else {
            throw CloudKitError.notAvailable
        }
        try await ensureCustomZone()
    }

    private func performSyncMutation<T>(
        successLog: String,
        failureLog: String,
        _ operation: () async throws -> T
    ) async throws -> T {
        syncStatus = .syncing
        defer { syncStatus = .idle }

        do {
            let result = try await operation()
            lastSyncDate = Date()
            logger.info("\(successLog)")
            return result
        } catch {
            logger.error("\(failureLog): \(error.localizedDescription)")
            syncStatus = .error(error.localizedDescription)
            throw error
        }
    }

    // MARK: - Subscriptions

    func subscribeToChanges() async {
        await ensureAccountStatusChecked()
        guard isSyncEnabled, isAvailable else { return }

        let subscriptionID = CloudKitSyncConstants.databaseSubscriptionID

        let notification = CKSubscription.NotificationInfo()
        notification.shouldSendContentAvailable = true

        let subscription = CKDatabaseSubscription(subscriptionID: subscriptionID)
        subscription.notificationInfo = notification

        do {
            if let existing = try? await database.subscription(for: subscriptionID) as? CKDatabaseSubscription,
               existing.notificationInfo?.shouldSendContentAvailable == true {
                guard !Task.isCancelled, isSyncEnabled else { return }
                logger.debug("CloudKit database subscription already configured")
                return
            }

            guard !Task.isCancelled, isSyncEnabled else { return }
            try await database.save(subscription)
            guard !Task.isCancelled, isSyncEnabled else { return }
            logger.info("Subscribed to database changes")
        } catch {
            logger.error("Failed to subscribe to database changes: \(error.localizedDescription)")
        }
    }

    // MARK: - Force Sync

    func forceSync() async {
        lastSyncDate = nil
        accountStatusChecked = false
        clearChangeToken()
        await requestAccountStatusRefresh().value
    }

    // MARK: - Cleanup

    /// Delete all records from CloudKit (use with caution!)
    func deleteAllRecords(matchingRecordTypes recordTypes: Set<String>) async throws {
        guard isAvailable else {
            throw CloudKitError.notAvailable
        }

        try await ensureCustomZone()

        syncStatus = .syncing
        defer { syncStatus = .idle }

        let records = try await withZoneRetry {
            try await fetchAllRecordsFromCloudKit()
        }
        let recordIDs = records
            .filter { recordTypes.contains($0.recordType) }
            .map(\.recordID)

        // Batch delete
        if !recordIDs.isEmpty {
            let cancellation = CloudKitOperationCancellationHandle()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    let operation = CKModifyRecordsOperation(recordsToSave: nil, recordIDsToDelete: recordIDs)
                    operation.qualityOfService = .userInitiated

                    operation.modifyRecordsResultBlock = { result in
                        switch result {
                        case .success:
                            continuation.resume()
                        case .failure(let error):
                            continuation.resume(throwing: error)
                        }
                    }

                    cancellation.setOperation(operation)
                    self.database.add(operation)
                }
            } onCancel: {
                cancellation.cancel()
            }
        }

        logger.info("Deleted \(recordIDs.count) CloudKit records")
        lastSyncDate = Date()
    }

}

// MARK: - CloudKit Error

nonisolated enum CloudKitError: LocalizedError, Equatable {
    case notAvailable
    case recordNotFound
    case encodingFailed
    case decodingFailed
    case recordFetchFailed(recordName: String, message: String)

    var errorDescription: String? {
        switch self {
        case .notAvailable: return "iCloud is not available"
        case .recordNotFound: return "Record not found"
        case .encodingFailed: return "Failed to encode data"
        case .decodingFailed: return "Failed to decode data"
        case .recordFetchFailed(let recordName, let message):
            return "Failed to fetch CloudKit record \(recordName): \(message)"
        }
    }
}
