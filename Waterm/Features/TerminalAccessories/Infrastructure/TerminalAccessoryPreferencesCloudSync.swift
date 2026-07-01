import CloudKit
import Foundation

@MainActor
final class TerminalAccessoryCloudKitProfileSyncService: TerminalAccessoryCloudProfileSyncing {
    private enum TerminalAccessoryCloudKitRecord {
        static let recordType = "UserPreference"
    }

    private let cloudKit: CloudKitManager

    init(cloudKit: CloudKitManager) {
        self.cloudKit = cloudKit
    }

    func syncTerminalAccessoryProfile(_ localProfile: TerminalAccessoryProfile) async throws -> TerminalAccessoryProfile {
        cloudKit.syncStatus = .syncing
        defer { cloudKit.syncStatus = .idle }

        let recordID = CKRecord.ID(recordName: TerminalAccessoryProfile.recordName, zoneID: cloudKit.recordZoneID)
        let normalizedLocal = localProfile.normalized()

        var baseRecord: CKRecord?
        var mergedProfile = normalizedLocal

        do {
            if let remoteRecord = try await cloudKit.fetchRecord(named: TerminalAccessoryProfile.recordName) {
                baseRecord = remoteRecord
                if let remoteProfile = decodeTerminalAccessoryProfile(from: remoteRecord) {
                    let normalizedRemote = remoteProfile.normalized()
                    mergedProfile = TerminalAccessoryProfile.merged(local: normalizedLocal, remote: normalizedRemote).normalized()
                    if mergedProfile == normalizedRemote {
                        cloudKit.lastSyncDate = Date()
                        return normalizedRemote
                    }
                }
            }
        } catch let ckError as CKError where ckError.code == .unknownItem || ckError.code == .zoneNotFound {
            baseRecord = nil
            mergedProfile = normalizedLocal
        }

        var attempts = 0
        while attempts < 4 {
            attempts += 1

            let candidateRecord = try makeTerminalAccessoryRecord(
                from: mergedProfile,
                recordID: recordID,
                existingRecord: baseRecord
            )

            do {
                try await cloudKit.saveCloudKitRecord(
                    candidateRecord,
                    successLog: "Saved terminal accessory profile to CloudKit",
                    failureLog: "Failed to save terminal accessory profile",
                    savePolicy: .ifServerRecordUnchanged
                )
                return mergedProfile
            } catch {
                if let serverRecord = cloudKit.extractServerRecord(from: error),
                   let serverProfile = decodeTerminalAccessoryProfile(from: serverRecord) {
                    let normalizedRemote = serverProfile.normalized()
                    let conflictResolved = TerminalAccessoryProfile.merged(local: mergedProfile, remote: normalizedRemote).normalized()

                    if conflictResolved == normalizedRemote {
                        cloudKit.lastSyncDate = Date()
                        return normalizedRemote
                    }

                    mergedProfile = conflictResolved
                    baseRecord = serverRecord
                    continue
                }

                if cloudKit.isUnknownItemError(error) {
                    baseRecord = nil
                    continue
                }

                throw error
            }
        }

        throw CloudKitError.recordNotFound
    }

    private func decodeTerminalAccessoryProfile(from record: CKRecord) -> TerminalAccessoryProfile? {
        guard let payload = record["payload"] as? Data else {
            return nil
        }

        guard var profile = try? JSONDecoder().decode(TerminalAccessoryProfile.self, from: payload) else {
            return nil
        }

        if let schemaVersion = record["schemaVersion"] as? Int, schemaVersion > 0 {
            profile.schemaVersion = schemaVersion
        }

        if let updatedAt = record["updatedAt"] as? Date, updatedAt > profile.updatedAt {
            profile.updatedAt = updatedAt
        }

        if let writerDeviceID = record["lastWriterDeviceId"] as? String, !writerDeviceID.isEmpty {
            profile.lastWriterDeviceId = writerDeviceID
        }

        return profile.normalized()
    }

    private func makeTerminalAccessoryRecord(
        from profile: TerminalAccessoryProfile,
        recordID: CKRecord.ID,
        existingRecord: CKRecord? = nil
    ) throws -> CKRecord {
        let normalizedProfile = profile.normalized()
        let payload: Data
        do {
            payload = try JSONEncoder().encode(normalizedProfile)
        } catch {
            throw CloudKitError.encodingFailed
        }

        let record = existingRecord ?? CKRecord(recordType: TerminalAccessoryCloudKitRecord.recordType, recordID: recordID)
        record["schemaVersion"] = normalizedProfile.schemaVersion
        record["payload"] = payload
        record["updatedAt"] = normalizedProfile.updatedAt
        record["lastWriterDeviceId"] = normalizedProfile.lastWriterDeviceId
        return record
    }
}
