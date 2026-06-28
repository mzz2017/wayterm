import Foundation
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
