import CloudKit
import Foundation

nonisolated final class CloudKitZoneChangeBatchCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [CKRecord] = []
    private var deletions: [CloudKitManager.Deletion] = []
    private var serverChangeToken: CKServerChangeToken?
    private var moreComing = false
    private var recordFailures: [(recordID: CKRecord.ID, error: Error)] = []

    func recordWasChanged(recordID: CKRecord.ID, result: Result<CKRecord, Error>) {
        lock.withLock {
            switch result {
            case .success(let record):
                records.append(record)
            case .failure(let error):
                recordFailures.append((recordID: recordID, error: error))
            }
        }
    }

    func recordWithIDWasDeleted(recordID: CKRecord.ID, recordType: CKRecord.RecordType) {
        lock.withLock {
            deletions.append(CloudKitManager.Deletion(recordID: recordID, recordType: recordType))
        }
    }

    func recordZoneFetchSucceeded(serverChangeToken: CKServerChangeToken?, moreComing: Bool) {
        lock.withLock {
            self.serverChangeToken = serverChangeToken
            self.moreComing = moreComing
        }
    }

    func makeBatch() throws -> CloudKitManager.ZoneChangeBatch {
        try lock.withLock {
            if let failure = recordFailures.first {
                throw CloudKitError.recordFetchFailed(
                    recordName: failure.recordID.recordName,
                    message: failure.error.localizedDescription
                )
            }

            return CloudKitManager.ZoneChangeBatch(
                records: records,
                deletions: deletions,
                serverChangeToken: serverChangeToken,
                moreComing: moreComing
            )
        }
    }
}
