import Foundation
import CloudKit
import Testing
@testable import VVTerm

// Test Context:
// CloudKitSyncCoordinator owns pending CloudKit mutation draining. Callers from
// server, theme, and accessory managers may all request drain concurrently; each
// request must be awaitable until the active drain exits. Fakes avoid CloudKit
// transport and expose only ordering/cancellation semantics.

@Suite(.serialized)
@MainActor
struct CloudKitSyncCoordinatorLifecycleTests {
    @Test
    func pendingServerMutationStoresPayloadThatCanBeDecodedForOverlay() throws {
        let coordinator = CloudKitSyncCoordinator.makeForTesting(
            storageKey: "CloudKitSyncCoordinatorLifecycleTests.\(UUID().uuidString)",
            syncPendingMutation: { _ in }
        )
        let server = Server(
            workspaceId: UUID(),
            name: "Pending Payload",
            host: "example.test",
            username: "user"
        )

        // Given a server upsert is enqueued while CloudKit sync may be offline.
        coordinator.enqueueServerUpsert(server)

        // When feature code reads the pending queue snapshot for local overlay.
        let mutation = try #require(coordinator.snapshot().first)
        let decodedPayload = try mutation.decodedPayload(as: Server.self)
        let decoded = try #require(decodedPayload)

        // Then the Core pending queue stores a generic payload that preserves
        // the feature-owned domain value for the feature adapter to decode.
        #expect(decoded.id == server.id)
        #expect(decoded.name == "Pending Payload")
        #expect(mutation.entity == .server)
        #expect(mutation.operation == .upsert)
    }

    @Test
    func legacyPendingServerMutationDecodesServerFieldIntoPayload() throws {
        let server = Server(
            workspaceId: UUID(),
            name: "Legacy Pending",
            host: "legacy.example.test",
            username: "user"
        )
        let legacy = LegacyPendingServerMutation(
            id: UUID(),
            entity: .server,
            operation: .upsert,
            entityKey: server.id.uuidString,
            server: server,
            createdAt: Date(),
            retryCount: 0
        )

        // Given a pending queue item persisted before Core moved domain values
        // into a generic payload.
        let data = try JSONEncoder().encode(legacy)

        // When the current Core queue model decodes it.
        let mutation = try JSONDecoder().decode(PendingCloudKitMutation.self, from: data)
        let decodedPayload = try mutation.decodedPayload(as: Server.self)
        let decoded = try #require(decodedPayload)

        // Then legacy offline writes still round-trip for sync and local overlay.
        #expect(decoded.id == server.id)
        #expect(decoded.host == "legacy.example.test")
        #expect(mutation.entityKey == server.id.uuidString)
    }

    @Test
    func pendingQueueLoadKeepsValidMutationsWhenOnePersistedItemIsCorrupt() throws {
        let storageKey = "CloudKitSyncCoordinatorLifecycleTests.\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: storageKey) }
        let firstID = UUID()
        let corruptID = UUID()
        let secondID = UUID()
        let persistedJSON = """
        [
          {
            "id": "\(firstID.uuidString)",
            "entity": "server",
            "operation": "delete",
            "entityKey": "server-one",
            "createdAt": 0,
            "retryCount": 0
          },
          {
            "id": "\(corruptID.uuidString)",
            "entity": "unknown-future-entity",
            "operation": "delete",
            "entityKey": "corrupt",
            "createdAt": 0,
            "retryCount": 0
          },
          {
            "id": "\(secondID.uuidString)",
            "entity": "workspace",
            "operation": "delete",
            "entityKey": "workspace-two",
            "createdAt": 0,
            "retryCount": 0
          }
        ]
        """
        UserDefaults.standard.set(Data(persistedJSON.utf8), forKey: storageKey)

        // Given one persisted pending mutation cannot decode, while surrounding
        // mutations are still valid local offline work.
        let queue = PendingCloudKitSyncQueue(storageKey: storageKey)

        // When the queue restores from UserDefaults.
        let snapshot = queue.snapshot()

        // Then the corrupt item is quarantined instead of dropping the whole
        // pending sync queue and losing unrelated offline user changes.
        #expect(snapshot.map(\.entityKey) == ["server-one", "workspace-two"])
        #expect(snapshot.map(\.id) == [firstID, secondID])
    }

    @Test
    func pendingDeleteIsRemovedWhenCloudKitPartialFailureReportsMissingRecord() async throws {
        let syncSettingsRestore = SyncSettingsRestore()
        syncSettingsRestore.setEnabled(true)
        defer { syncSettingsRestore.restore() }

        let storageKey = "CloudKitSyncCoordinatorLifecycleTests.\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: storageKey) }
        let entityKey = UUID().uuidString
        let missingRecordID = CKRecord.ID(recordName: entityKey)
        let missingRecordError = CKError(.unknownItem)
        let partialFailure = CKError(
            .partialFailure,
            userInfo: [
                CKPartialErrorsByItemIDKey: [missingRecordID: missingRecordError]
            ]
        )
        let coordinator = CloudKitSyncCoordinator.makeForTesting(
            storageKey: storageKey,
            syncPendingMutation: { _ in throw partialFailure }
        )

        // Given a pending delete races with CloudKit state that already removed
        // the record and reports the miss as a nested partial failure.
        coordinator.enqueuePendingMutation(.delete(entity: .server, entityKey: entityKey))

        // When the pending mutation drain reaches that delete.
        await coordinator.drainPendingMutations()

        // Then the delete is treated as idempotently complete instead of being
        // retried forever and blocking later offline sync work.
        #expect(coordinator.snapshot().isEmpty)
    }

    @Test
    func pendingDrainStopsBeforeLaterDeleteWhenEarlierOrderedDeleteFails() async throws {
        let syncSettingsRestore = SyncSettingsRestore()
        syncSettingsRestore.setEnabled(true)
        defer { syncSettingsRestore.restore() }

        let storageKey = "CloudKitSyncCoordinatorLifecycleTests.\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: storageKey) }
        let probe = CloudKitDrainProbe()
        let failingServerID = UUID().uuidString
        let workspaceID = UUID().uuidString
        let unrelatedThemeID = UUID().uuidString
        let coordinator = CloudKitSyncCoordinator.makeForTesting(
            storageKey: storageKey,
            syncPendingMutation: { mutation in
                await probe.record("\(mutation.entity.rawValue):\(mutation.operation.rawValue):\(mutation.entityKey)")
                if mutation.entity == .server && mutation.operation == .delete {
                    throw CloudKitDrainTestError.transientServerDelete
                }
            }
        )

        // Given a child server delete must complete before the parent
        // workspace delete can safely reach CloudKit, while unrelated pending
        // sync work should still be allowed to make progress.
        coordinator.enqueuePendingMutation(.delete(entity: .workspace, entityKey: workspaceID))
        coordinator.enqueuePendingMutation(.delete(entity: .server, entityKey: failingServerID))
        coordinator.enqueuePendingMutation(.delete(entity: .terminalTheme, entityKey: unrelatedThemeID))

        // When the earlier ordered server delete fails with a retryable error.
        await coordinator.drainPendingMutations()

        // Then the later workspace delete is not attempted in the same drain,
        // preventing remote orphan/resurrection when a child tombstone failed.
        #expect(
            await probe.events() == [
                "server:delete:\(failingServerID)",
                "terminalTheme:delete:\(unrelatedThemeID)"
            ],
            "Pending CloudKit drain must block dependent later work after a retryable delete failure without stalling unrelated sync groups."
        )
        #expect(
            coordinator.snapshot().contains { $0.entity == .workspace && $0.entityKey == workspaceID },
            "The parent workspace delete must remain queued until earlier child deletes have completed."
        )
        #expect(
            !coordinator.snapshot().contains { $0.entity == .terminalTheme && $0.entityKey == unrelatedThemeID },
            "Unrelated pending sync work should still complete when a server/workspace dependency group is blocked."
        )
    }

    @Test
    func pendingServerAndWorkspaceDeletesUseEntityKeyWhenPayloadIsMissing() async throws {
        let cloudKit = RecordingPendingCloudKitRecordSync()
        let serverID = UUID()
        let workspaceID = UUID()

        // Given pending delete mutations survived with entity keys but without
        // feature payloads.
        let serverDelete = PendingCloudKitMutation.delete(
            entity: .server,
            entityKey: serverID.uuidString,
            payload: nil
        )
        let workspaceDelete = PendingCloudKitMutation.delete(
            entity: .workspace,
            entityKey: workspaceID.uuidString,
            payload: nil
        )

        // When the live CloudKit adapter drains those deletes.
        try await CloudKitPendingMutationLiveSync.sync(serverDelete, cloudKit: cloudKit)
        try await CloudKitPendingMutationLiveSync.sync(workspaceDelete, cloudKit: cloudKit)

        // Then the adapter issues record deletes from entityKey instead of
        // silently succeeding without touching CloudKit.
        #expect(
            cloudKit.deletedRecordNames == [
                serverID.uuidString,
                workspaceID.uuidString
            ],
            "Pending server/workspace delete must use entityKey when payload is unavailable."
        )
        #expect(
            cloudKit.savedRecordNames.isEmpty,
            "Pending delete mutations must not be converted into save operations."
        )
    }

    @Test
    func duplicateDrainWaitsForActiveDrainToFinish() async throws {
        let syncSettingsRestore = SyncSettingsRestore()
        syncSettingsRestore.setEnabled(true)
        defer { syncSettingsRestore.restore() }

        let probe = CloudKitDrainProbe()
        let releaseDrain = CloudKitDrainGate()
        let coordinator = CloudKitSyncCoordinator.makeForTesting(
            storageKey: "CloudKitSyncCoordinatorLifecycleTests.\(UUID().uuidString)",
            syncPendingMutation: { mutation in
                await probe.record("sync-start:\(mutation.entityKey)")
                await releaseDrain.wait()
                await probe.record("sync-end:\(mutation.entityKey)")
            }
        )
        let server = Server(
            workspaceId: UUID(),
            name: "Pending",
            host: "example.test",
            username: "user"
        )

        // Given a pending mutation drain is blocked inside CloudKit work.
        coordinator.enqueueServerUpsert(server)
        let firstDrain = Task {
            await coordinator.drainPendingMutations()
            await probe.record("first-return")
        }
        await probe.waitForCount(1)

        // When another caller asks to drain while the first drain is active.
        let secondDrain = Task {
            await coordinator.drainPendingMutations()
            await probe.record("second-return")
        }
        try await Task.sleep(for: .milliseconds(20))

        // Then the second caller should remain behind the active drain instead
        // of reporting completion early.
        let eventsBeforeRelease = await probe.events()
        #expect(
            !eventsBeforeRelease.contains("second-return"),
            "Concurrent CloudKit pending-drain callers must wait for the active drain to exit."
        )

        await releaseDrain.open()
        await firstDrain.value
        await secondDrain.value

        let eventsAfterRelease = await probe.events()
        #expect(
            Array(eventsAfterRelease.prefix(2)) == [
                "sync-start:\(server.id.uuidString)",
                "sync-end:\(server.id.uuidString)"
            ],
            "Both CloudKit pending-drain callers should complete only after the shared drain finishes."
        )
        #expect(
            Set(eventsAfterRelease.dropFirst(2)) == ["first-return", "second-return"],
            "Both pending-drain callers should resume after the active CloudKit drain exits."
        )
    }

    @Test
    func duplicateDrainRequestIsRepresentedByExplicitStateUntilActiveDrainCompletes() async throws {
        let syncSettingsRestore = SyncSettingsRestore()
        syncSettingsRestore.setEnabled(true)
        defer { syncSettingsRestore.restore() }

        let probe = CloudKitDrainProbe()
        let releaseDrain = CloudKitDrainGate()
        let coordinator = CloudKitSyncCoordinator.makeForTesting(
            storageKey: "CloudKitSyncCoordinatorLifecycleTests.\(UUID().uuidString)",
            syncPendingMutation: { mutation in
                await probe.record("sync-start:\(mutation.entityKey)")
                await releaseDrain.wait()
            }
        )
        let server = Server(
            workspaceId: UUID(),
            name: "Explicit Drain State",
            host: "example.test",
            username: "user"
        )

        coordinator.enqueueServerUpsert(server)
        let firstDrain = Task {
            await coordinator.drainPendingMutations()
        }
        await probe.waitForCount(1)
        #expect(
            coordinator.drainState == .draining,
            "The active CloudKit pending drain should expose an explicit draining state."
        )

        let secondDrain = Task {
            await coordinator.drainPendingMutations()
        }
        try await Task.sleep(for: .milliseconds(20))

        #expect(
            coordinator.drainState == .drainAgainRequested,
            "A duplicate CloudKit pending-drain intent should be visible as an explicit requested-again state."
        )

        await releaseDrain.open()
        await firstDrain.value
        await secondDrain.value

        #expect(
            coordinator.drainState == .idle,
            "CloudKit pending-drain state should return to idle only after all waiting callers complete."
        )
    }

    @Test
    func pendingDrainStopsBeforeNextMutationWhenSyncIsDisabledMidDrain() async throws {
        let syncSettingsRestore = SyncSettingsRestore()
        syncSettingsRestore.setEnabled(true)
        defer { syncSettingsRestore.restore() }

        let probe = CloudKitDrainProbe()
        let coordinator = CloudKitSyncCoordinator.makeForTesting(
            storageKey: "CloudKitSyncCoordinatorLifecycleTests.\(UUID().uuidString)",
            syncPendingMutation: { mutation in
                await probe.record("sync:\(mutation.entityKey)")
                syncSettingsRestore.setEnabled(false)
            }
        )
        let firstServer = Server(
            workspaceId: UUID(),
            name: "First Pending",
            host: "first.example.test",
            username: "user"
        )
        let secondServer = Server(
            workspaceId: UUID(),
            name: "Second Pending",
            host: "second.example.test",
            username: "user"
        )

        // Given two metadata mutations are queued while sync is enabled.
        coordinator.enqueueServerUpsert(firstServer)
        coordinator.enqueueServerUpsert(secondServer)

        // When the user disables sync while the first mutation is being sent.
        await coordinator.drainPendingMutations()

        // Then the active drain stops before sending later metadata after the
        // cross-device sync control has been disabled.
        #expect(
            await probe.events() == ["sync:\(firstServer.id.uuidString)"],
            "CloudKit pending drain must re-check SyncSettings before each mutation so disabling sync stops later uploads."
        )
        #expect(
            coordinator.snapshot().map(\.entityKey) == [secondServer.id.uuidString],
            "Mutations not sent because sync was disabled should remain queued for a later explicit sync-enable drain."
        )
    }
}

private struct LegacyPendingServerMutation: Encodable {
    let id: UUID
    let entity: PendingCloudKitEntity
    let operation: PendingCloudKitOperation
    let entityKey: String
    let server: Server
    let createdAt: Date
    let retryCount: Int
    let nextRetryAt: Date? = nil
    let lastErrorCode: String? = nil
    let lastErrorDescription: String? = nil
}

private final class SyncSettingsRestore {
    private let previousValue: Any?

    init() {
        previousValue = UserDefaults.standard.object(forKey: SyncSettings.enabledKey)
    }

    func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: SyncSettings.enabledKey)
    }

    func restore() {
        if let previousValue {
            UserDefaults.standard.set(previousValue, forKey: SyncSettings.enabledKey)
        } else {
            UserDefaults.standard.removeObject(forKey: SyncSettings.enabledKey)
        }
    }
}

private enum CloudKitDrainTestError: LocalizedError {
    case transientServerDelete

    var errorDescription: String? {
        switch self {
        case .transientServerDelete:
            return "Transient server delete failure"
        }
    }
}

@MainActor
private final class RecordingPendingCloudKitRecordSync: PendingCloudKitRecordSyncing {
    let recordZoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: CKCurrentUserDefaultName)
    private(set) var savedRecordNames: [String] = []
    private(set) var deletedRecordNames: [String] = []

    func savePendingCloudKitRecord(
        _ record: CKRecord,
        successLog: String,
        failureLog: String
    ) async throws {
        savedRecordNames.append(record.recordID.recordName)
    }

    func deletePendingCloudKitRecord(
        named recordName: String,
        successLog: String,
        failureLog: String
    ) async throws {
        deletedRecordNames.append(recordName)
    }
}

private actor CloudKitDrainProbe {
    private var recordedEvents: [String] = []
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func record(_ event: String) {
        recordedEvents.append(event)
        resumeReadyContinuations()
    }

    func events() -> [String] {
        recordedEvents
    }

    func waitForCount(_ count: Int) async {
        if recordedEvents.count >= count { return }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
        if recordedEvents.count < count {
            await waitForCount(count)
        }
    }

    private func resumeReadyContinuations() {
        let ready = continuations
        continuations.removeAll()
        for continuation in ready {
            continuation.resume()
        }
    }
}

private actor CloudKitDrainGate {
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
