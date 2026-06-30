import CloudKit
import Foundation
import Testing
@testable import VVTerm

// Test Context:
// These tests protect CloudKit incremental sync from acknowledging incomplete
// zone-change batches. CloudKit can report individual record fetch failures
// through recordWasChangedBlock while the overall zone operation later succeeds;
// that must not produce a batch whose change token can be committed.
struct CloudKitZoneChangeBatchCollectorTests {
    @Test
    func recordFailurePreventsReturningCommittableBatch() throws {
        let collector = CloudKitZoneChangeBatchCollector()
        let recordID = CKRecord.ID(
            recordName: "server-failed",
            zoneID: CKRecordZone.ID(zoneName: "VVTermTestZone")
        )
        let failure = NSError(
            domain: CKErrorDomain,
            code: CKError.networkUnavailable.rawValue,
            userInfo: [NSLocalizedDescriptionKey: "record fetch failed"]
        )

        // Given CloudKit delivered a per-record failure.
        collector.recordWasChanged(recordID: recordID, result: .failure(failure))

        // When the enclosing zone fetch still completes successfully.
        collector.recordZoneFetchSucceeded(serverChangeToken: nil, moreComing: false)

        // Then the batch is rejected so the caller cannot acknowledge a fetch
        // that would skip the failed record on the next pass.
        #expect(
            throws: CloudKitError.recordFetchFailed(
                recordName: "server-failed",
                message: "record fetch failed"
            )
        ) {
            _ = try collector.makeBatch()
        }
    }

    @Test
    func successfulChangesAndDeletionsReturnBatch() throws {
        let collector = CloudKitZoneChangeBatchCollector()
        let zoneID = CKRecordZone.ID(zoneName: "VVTermTestZone")
        let recordID = CKRecord.ID(recordName: "server-1", zoneID: zoneID)
        let record = CKRecord(recordType: "Server", recordID: recordID)
        let deletedID = CKRecord.ID(recordName: "server-deleted", zoneID: zoneID)

        // Given CloudKit delivered a changed record and a deletion.
        collector.recordWasChanged(recordID: recordID, result: .success(record))
        collector.recordWithIDWasDeleted(recordID: deletedID, recordType: "Server")

        // When the enclosing zone fetch completes successfully.
        collector.recordZoneFetchSucceeded(serverChangeToken: nil, moreComing: true)
        let batch = try collector.makeBatch()

        // Then all delivered changes remain available to the sync apply layer.
        #expect(batch.records.map(\.recordID) == [recordID], "Changed records should be preserved in order.")
        #expect(batch.deletions.map(\.recordID) == [deletedID], "Deleted records should be preserved in order.")
        #expect(batch.moreComing, "The CloudKit pagination flag should be preserved.")
    }
}
