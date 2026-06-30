import CloudKit
import Foundation
import os.log

extension CloudKitManager {
    struct ZoneChangeBatch {
        let records: [CKRecord]
        let deletions: [Deletion]
        let serverChangeToken: CKServerChangeToken?
        let moreComing: Bool
    }

    struct Deletion {
        let recordID: CKRecord.ID
        let recordType: CKRecord.RecordType
    }

    // MARK: - Change Tokens

    func loadChangeToken() -> CKServerChangeToken? {
        guard let data = UserDefaults.standard.data(forKey: changeTokenKey) else {
            return nil
        }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data)
    }

    func saveChangeToken(_ token: CKServerChangeToken) {
        guard let data = try? NSKeyedArchiver.archivedData(
            withRootObject: token,
            requiringSecureCoding: true
        ) else {
            return
        }
        UserDefaults.standard.set(data, forKey: changeTokenKey)
    }

    func clearChangeToken() {
        UserDefaults.standard.removeObject(forKey: changeTokenKey)
    }

    func isChangeTokenExpired(_ error: Error) -> Bool {
        guard let ckError = error as? CKError else {
            return false
        }
        return ckError.code == .changeTokenExpired
    }

    // MARK: - Record Fetching

    func fetchAllRecordsFromCloudKit(
        matchingRecordTypes recordTypes: Set<String>? = nil
    ) async throws -> [CKRecord] {
        try await ensureCustomZone()
        let zoneID = recordZoneID
        var token: CKServerChangeToken?
        var records: [CKRecord] = []
        var moreComing = true

        while moreComing {
            let batch = try await fetchZoneChanges(zoneID: zoneID, previousToken: token)
            if let recordTypes {
                records.append(contentsOf: batch.records.filter { recordTypes.contains($0.recordType) })
            } else {
                records.append(contentsOf: batch.records)
            }
            token = batch.serverChangeToken
            moreComing = batch.moreComing
        }

        return records
    }

    func fetchZoneChanges(
        zoneID: CKRecordZone.ID,
        previousToken: CKServerChangeToken?
    ) async throws -> ZoneChangeBatch {
        let logger = logger
        let cancellation = CloudKitOperationCancellationHandle()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ZoneChangeBatch, Error>) in
                let configuration = CKFetchRecordZoneChangesOperation.ZoneConfiguration(
                    previousServerChangeToken: previousToken,
                    resultsLimit: nil,
                    desiredKeys: nil
                )
                let operation = CKFetchRecordZoneChangesOperation(
                    recordZoneIDs: [zoneID],
                    configurationsByRecordZoneID: [zoneID: configuration]
                )
                operation.qualityOfService = .userInitiated

                let batchCollector = CloudKitZoneChangeBatchCollector()
                var zoneError: Error?

                operation.recordWasChangedBlock = { recordID, recordResult in
                    if case .failure(let error) = recordResult {
                        logger.error(
                            "Failed to fetch record \(recordID.recordName): \(error.localizedDescription)"
                        )
                    }
                    batchCollector.recordWasChanged(recordID: recordID, result: recordResult)
                }

                operation.recordWithIDWasDeletedBlock = { recordID, recordType in
                    batchCollector.recordWithIDWasDeleted(recordID: recordID, recordType: recordType)
                }

                operation.recordZoneFetchResultBlock = { _, result in
                    switch result {
                    case .success(let info):
                        batchCollector.recordZoneFetchSucceeded(
                            serverChangeToken: info.serverChangeToken,
                            moreComing: info.moreComing
                        )
                    case .failure(let error):
                        zoneError = error
                    }
                }

                operation.fetchRecordZoneChangesResultBlock = { result in
                    switch result {
                    case .success:
                        if let zoneError = zoneError {
                            continuation.resume(throwing: zoneError)
                        } else {
                            do {
                                continuation.resume(returning: try batchCollector.makeBatch())
                            } catch {
                                continuation.resume(throwing: error)
                            }
                        }
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

    // MARK: - Record Mutation

    /// Save a record using CKModifyRecordsOperation with changedKeys policy.
    /// This handles both insert (new record) and update (existing record).
    func saveRecordWithUpsert(_ record: CKRecord) async throws {
        try await saveRecord(record, savePolicy: .changedKeys)
    }

    func saveRecord(
        _ record: CKRecord,
        savePolicy: CKModifyRecordsOperation.RecordSavePolicy
    ) async throws {
        let cancellation = CloudKitOperationCancellationHandle()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let operation = CKModifyRecordsOperation(recordsToSave: [record], recordIDsToDelete: nil)
                operation.savePolicy = savePolicy
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
                database.add(operation)
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    // MARK: - Error Helpers

    func extractServerRecord(from error: Error) -> CKRecord? {
        guard let ckError = error as? CKError else { return nil }

        if ckError.code == .serverRecordChanged {
            return ckError.userInfo[CKRecordChangedErrorServerRecordKey] as? CKRecord
        }

        if ckError.code == .partialFailure,
           let partialErrors = ckError.userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: Error] {
            for partialError in partialErrors.values {
                if let serverRecord = extractServerRecord(from: partialError) {
                    return serverRecord
                }
            }
        }

        return nil
    }

    func isUnknownItemError(_ error: Error) -> Bool {
        guard let ckError = error as? CKError else { return false }

        if ckError.code == .unknownItem || ckError.code == .zoneNotFound {
            return true
        }

        if ckError.code == .partialFailure,
           let partialErrors = ckError.userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: Error] {
            return partialErrors.values.contains { isUnknownItemError($0) }
        }

        return false
    }

    /// Check if an error is a schema-related error (record type not found).
    static func isSchemaError(_ error: Error) -> Bool {
        if let ckError = error as? CKError {
            switch ckError.code {
            case .unknownItem, .invalidArguments:
                // unknownItem: record type doesn't exist; invalidArguments: field/index issues.
                return true
            default:
                return false
            }
        }
        let message = error.localizedDescription.lowercased()
        return message.contains("record type") || message.contains("field") || message.contains("queryable")
    }

    // MARK: - Record Zone

    func ensureCustomZone() async throws {
        if zoneReady {
            return
        }

        if let task = ensureZoneTask {
            try await task.value
            return
        }

        let task = Task { try await self.createZoneIfNeeded() }
        ensureZoneTask = task
        defer { ensureZoneTask = nil }
        try await task.value
    }

    func createZoneIfNeeded() async throws {
        let results = try await database.recordZones(for: [recordZoneID])
        if let result = results[recordZoneID] {
            switch result {
            case .success:
                setZoneReady(true)
                return
            case .failure(let error):
                if isZoneNotFound(error) {
                    _ = try await database.modifyRecordZones(saving: [recordZone], deleting: [])
                    setZoneReady(true)
                    return
                }
                throw error
            }
        }

        _ = try await database.modifyRecordZones(saving: [recordZone], deleting: [])
        setZoneReady(true)
    }

    func setZoneReady(_ ready: Bool) {
        zoneReady = ready
        UserDefaults.standard.set(ready, forKey: zoneReadyKey)
    }

    func withZoneRetry<T>(_ operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch {
            guard isZoneNotFound(error) else {
                throw error
            }

            logger.warning("CloudKit zone was missing during operation; recreating and retrying once")
            setZoneReady(false)
            try await ensureCustomZone()
            return try await operation()
        }
    }

    func isZoneNotFound(_ error: Error) -> Bool {
        guard let ckError = error as? CKError else {
            return false
        }
        return ckError.code == .zoneNotFound || ckError.code == .unknownItem
    }
}
