import CloudKit
import Foundation
import Testing
@testable import Waterm

// Test Context:
// These tests protect the server/workspace CloudKit semantic decode boundary.
// A transport-level fetch can succeed while an individual supported record is
// malformed. Such records must fail the fetched batch before ServerManager can
// commit the change token, otherwise that record can be skipped forever.
struct ServerCloudKitSyncServiceDecodeTests {
    @Test
    func malformedServerRecordFailsFetchedChangesBeforeCommitIsExposed() throws {
        let recordID = CKRecord.ID(recordName: UUID().uuidString)
        let malformedServer = CKRecord(recordType: "Server", recordID: recordID)
        malformedServer["workspaceId"] = UUID().uuidString
        malformedServer["name"] = "Broken"
        // host, username, port, and authMethod are intentionally missing.

        let fetched = CloudKitRecordChanges(
            records: [malformedServer],
            deletions: [],
            isFullFetch: false,
            changeToken: nil
        )

        // When a supported CloudKit Server record cannot be decoded.
        #expect(
            throws: ServerCloudKitSyncError.decodeFailed(
                recordType: "Server",
                recordName: recordID.recordName
            )
        ) {
            _ = try ServerCloudKitChangeDecoder.decode(fetched, commitFetchedChanges: nil)
        }
    }

    @Test
    func validServerAndWorkspaceRecordsDecodeIntoFetchedChanges() throws {
        let workspace = Workspace(id: UUID(), name: "Main", colorHex: "#00ff88", order: 0)
        let server = Server(
            id: UUID(),
            workspaceId: workspace.id,
            name: "Tencent",
            host: "sync-decode.example.com",
            username: "root"
        )
        let fetched = CloudKitRecordChanges(
            records: [
                workspace.toRecord(),
                server.toRecord()
            ],
            deletions: [],
            isFullFetch: true,
            changeToken: nil
        )

        // When all supported records are semantically valid.
        let changes = try ServerCloudKitChangeDecoder.decode(fetched, commitFetchedChanges: nil)

        // Then the decoded payload is passed through to ServerManager apply.
        #expect(changes.workspaces.map(\.id) == [workspace.id])
        #expect(changes.servers.map(\.id) == [server.id])
        #expect(changes.isFullFetch)
    }
}
