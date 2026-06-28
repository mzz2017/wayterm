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
