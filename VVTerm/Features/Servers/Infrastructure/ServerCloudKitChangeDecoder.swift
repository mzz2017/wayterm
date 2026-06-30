import CloudKit
import Foundation

nonisolated enum ServerCloudKitSyncError: LocalizedError, Equatable {
    case decodeFailed(recordType: String, recordName: String)

    var errorDescription: String? {
        switch self {
        case let .decodeFailed(recordType, recordName):
            return "Failed to decode CloudKit \(recordType) record \(recordName)"
        }
    }
}

nonisolated enum ServerCloudKitChangeDecoder {
    private enum RecordType {
        static let server = "Server"
        static let workspace = "Workspace"
    }

    static func decode(
        _ changes: CloudKitRecordChanges,
        commitFetchedChanges: (@MainActor () async -> Void)? = nil
    ) throws -> CloudKitChanges {
        var servers: [Server] = []
        var workspaces: [Workspace] = []
        var deletedServerIDs: [UUID] = []
        var deletedWorkspaceIDs: [UUID] = []

        for record in changes.records {
            switch record.recordType {
            case RecordType.server:
                guard let server = Server(from: record) else {
                    throw ServerCloudKitSyncError.decodeFailed(
                        recordType: record.recordType,
                        recordName: record.recordID.recordName
                    )
                }
                servers.append(server)
            case RecordType.workspace:
                guard let workspace = Workspace(from: record) else {
                    throw ServerCloudKitSyncError.decodeFailed(
                        recordType: record.recordType,
                        recordName: record.recordID.recordName
                    )
                }
                workspaces.append(workspace)
            default:
                break
            }
        }

        for deletion in changes.deletions {
            switch deletion.recordType {
            case RecordType.server:
                deletedServerIDs.append(try decodedDeletedID(from: deletion))
            case RecordType.workspace:
                deletedWorkspaceIDs.append(try decodedDeletedID(from: deletion))
            default:
                break
            }
        }

        return CloudKitChanges(
            servers: servers,
            workspaces: workspaces,
            deletedServerIDs: deletedServerIDs,
            deletedWorkspaceIDs: deletedWorkspaceIDs,
            isFullFetch: changes.isFullFetch,
            commitFetchedChanges: commitFetchedChanges
        )
    }

    private static func decodedDeletedID(from deletion: CloudKitManager.Deletion) throws -> UUID {
        guard let id = UUID(uuidString: deletion.recordID.recordName) else {
            throw ServerCloudKitSyncError.decodeFailed(
                recordType: deletion.recordType,
                recordName: deletion.recordID.recordName
            )
        }
        return id
    }
}
