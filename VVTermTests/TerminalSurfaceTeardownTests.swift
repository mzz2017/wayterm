import Foundation
import Testing
@testable import VVTerm

// Test Context:
// These tests protect terminal UI surface teardown rules. UI wrappers report
// disappeared surfaces; application-layer managers decide whether the surface is
// preserved for reuse or cleaned up because the entity closed.
// Target invariant: view disappearance pauses reusable surfaces without native
// teardown, while closed entities clean up exactly once and root closed-session
// cleanup remains tracked/awaitable through server teardown tasks. Detached
// Ghostty native handles invalidate callback userdata before native free so
// late FFI callbacks cannot resolve released UI surfaces.
// Fakes here record surface cleanup/pause callbacks only; they do not create
// Ghostty surfaces or open network connections. Update these tests only when the
// intended boundary between terminal UI surfaces and SSH runtime ownership
// changes.

@Suite(.serialized)
struct TerminalSurfaceTeardownTests {
    @Test
    func detachedSurfaceSchedulesNativeFreeWithoutRunningItInline() async throws {
        let recorder = TerminalSurfaceTeardownRecorder()
        let scheduler = TerminalSurfaceTeardownQueue(
            enqueue: { operation in
                recorder.enqueued += 1
                recorder.operation = operation
            }
        )

        let handle = Ghostty.Surface.NativeHandle(
            rawValue: nil,
            callbackContext: nil,
            freeNativeSurface: { recorder.freed += 1 }
        )

        handle.scheduleFree(on: scheduler)

        #expect(recorder.enqueued == 1)
        #expect(recorder.freed == 0)

        recorder.operation?()
        #expect(recorder.freed == 1)
    }

    @Test
    func nativeHandleInvalidatesCallbackContextBeforeNativeFreeAndOnlyOnce() {
        // Given a detached Ghostty native handle with an FFI callback context.
        let recorder = TerminalSurfaceCallbackInvalidationRecorder()
        let handle = Ghostty.Surface.NativeHandle(
            rawValue: nil,
            callbackContext: recorder,
            freeNativeSurface: { recorder.record("free") }
        )

        // When native teardown is requested more than once.
        handle.free()
        handle.free()

        // Then the callback context is invalidated before native free and the
        // idempotent native handle does not expose late callbacks on repeats.
        #expect(
            recorder.events == ["invalidate", "free"],
            "A detached Ghostty surface must invalidate userdata before native free, exactly once."
        )
    }

    @MainActor
    @Test
    func surfaceDetachPausesWithoutRunningRuntimeTeardown() {
        // Given a registry-owned surface test double and a runtime teardown
        // recorder that is intentionally not owned by the surface registry.
        let registry = TerminalSurfaceRegistry()
        let entityId = TerminalEntityID.session(UUID())
        let recorder = TerminalSurfaceRegistryRecorder()
        registry.registerForTesting(
            entityId: entityId,
            pause: { recorder.pauseCount += 1 },
            cleanup: { recorder.cleanupCount += 1 }
        )

        // When SwiftUI lifecycle detaches the surface without explicit cleanup.
        registry.detachSurface(for: entityId, cleanup: false)

        // Then the surface is paused only; SSH/runtime teardown remains outside
        // this registry's responsibility.
        #expect(recorder.pauseCount == 1)
        #expect(recorder.cleanupCount == 0)
        #expect(recorder.runtimeTeardownCount == 0)
    }

    @MainActor
    @Test
    func surfaceCleanupIsIdempotent() {
        // Given a registry-owned surface test double.
        let registry = TerminalSurfaceRegistry()
        let entityId = TerminalEntityID.pane(UUID())
        let recorder = TerminalSurfaceRegistryRecorder()
        registry.registerForTesting(
            entityId: entityId,
            pause: { recorder.pauseCount += 1 },
            cleanup: { recorder.cleanupCount += 1 }
        )

        // When cleanup is requested more than once for the same entity.
        registry.detachSurface(for: entityId, cleanup: true)
        registry.detachSurface(for: entityId, cleanup: true)

        // Then the underlying surface cleanup runs exactly once.
        #expect(recorder.cleanupCount == 1)
        #expect(recorder.pauseCount == 0)
    }

    @MainActor
    @Test
    func replacingSurfaceForSameEntityCleansPreviousSurface() {
        // Given a registry-owned Ghostty surface for an entity.
        let registry = TerminalSurfaceRegistry()
        let entityId = TerminalEntityID.session(UUID())
        let firstRecorder = TerminalSurfaceRegistryRecorder()
        let secondRecorder = TerminalSurfaceRegistryRecorder()
        registry.registerForTesting(
            entityId: entityId,
            pause: { firstRecorder.pauseCount += 1 },
            cleanup: { firstRecorder.cleanupCount += 1 }
        )

        // When SwiftUI recreates a terminal surface for the same entity.
        registry.registerForTesting(
            entityId: entityId,
            pause: { secondRecorder.pauseCount += 1 },
            cleanup: { secondRecorder.cleanupCount += 1 }
        )

        // Then the old UI/FFI surface is released immediately, while business
        // shell teardown remains outside the surface registry.
        #expect(
            firstRecorder.cleanupCount == 1,
            "Replacing a Ghostty surface for the same entity must release the old FFI/UI surface immediately."
        )
        #expect(firstRecorder.pauseCount == 0)
        #expect(firstRecorder.runtimeTeardownCount == 0)
        #expect(secondRecorder.cleanupCount == 0)

        registry.removeSurface(for: entityId, cleanup: true)

        #expect(secondRecorder.cleanupCount == 1)
    }

    @MainActor
    @Test
    func rootViewDisappearancePreservesLiveSessionSurfaceWithoutCleanup() async {
        let manager = ConnectionSessionManager.shared
        await manager.resetForTesting()

        let session = ConnectionSession(
            serverId: UUID(),
            title: "Live",
            connectionState: .connected
        )
        let recorder = TerminalSurfaceRegistryRecorder()
        manager.sessions = [session]
        manager.terminalSurfaceRegistry.registerForTesting(
            entityId: .session(session.id),
            pause: { recorder.pauseCount += 1 },
            cleanup: { recorder.cleanupCount += 1 }
        )

        // Given a live root session surface disappears because its view went away.
        let resolution = manager.handleSurfaceViewDisappeared(
            sessionId: session.id,
            serverId: session.serverId,
            reason: "test live root disappearance"
        )

        // Then the manager preserves it for reuse and only pauses rendering.
        #expect(resolution == .preservedForReuse)
        #expect(recorder.pauseCount == 1)
        #expect(recorder.cleanupCount == 0)
        #expect(manager.hasTerminal(for: session.id))

        await manager.resetForTesting()
    }

    @MainActor
    @Test
    func staleRootViewDisappearanceDoesNotPauseReplacementSurface() async {
        let manager = ConnectionSessionManager.shared
        await manager.resetForTesting()

        let session = ConnectionSession(
            serverId: UUID(),
            title: "Replacement",
            connectionState: .connected
        )
        let firstRecorder = TerminalSurfaceRegistryRecorder()
        let secondRecorder = TerminalSurfaceRegistryRecorder()
        manager.sessions = [session]
        let staleSurfaceToken = manager.terminalSurfaceRegistry.registerForTesting(
            entityId: .session(session.id),
            pause: { firstRecorder.pauseCount += 1 },
            cleanup: { firstRecorder.cleanupCount += 1 }
        )
        _ = manager.terminalSurfaceRegistry.registerForTesting(
            entityId: .session(session.id),
            pause: { secondRecorder.pauseCount += 1 },
            cleanup: { secondRecorder.cleanupCount += 1 }
        )

        // Given SwiftUI has already replaced a live root surface for the same
        // session, and the old representable is dismantled afterwards.
        let resolution = manager.handleSurfaceViewDisappeared(
            sessionId: session.id,
            serverId: session.serverId,
            surfaceToken: staleSurfaceToken,
            reason: "test stale root disappearance"
        )

        // Then the stale disappearance is ignored instead of pausing the latest
        // registered surface for the live session.
        #expect(resolution == .staleSurfaceIgnored)
        #expect(firstRecorder.cleanupCount == 1)
        #expect(secondRecorder.pauseCount == 0)
        #expect(secondRecorder.cleanupCount == 0)
        #expect(manager.hasTerminal(for: session.id))

        await manager.resetForTesting()
    }

    @MainActor
    @Test
    func rootViewDisappearanceTracksClosedSessionCleanupUntilAwaited() async {
        let manager = ConnectionSessionManager.shared
        await manager.resetForTesting()

        let sessionId = UUID()
        let serverId = UUID()
        let recorder = TerminalSurfaceRegistryRecorder()
        manager.terminalSurfaceRegistry.registerForTesting(
            entityId: .session(sessionId),
            pause: { recorder.pauseCount += 1 },
            cleanup: { recorder.cleanupCount += 1 }
        )

        // Given a root surface disappears after its session has already closed.
        let resolution = manager.handleSurfaceViewDisappeared(
            sessionId: sessionId,
            serverId: serverId,
            reason: "test closed root disappearance"
        )

        // Then cleanup is tracked as teardown work and is complete after awaiting it.
        #expect(resolution == .closedAndCleanedUp)
        await manager.waitForServerTeardownTasks(serverId)
        #expect(recorder.cleanupCount == 1)
        #expect(recorder.pauseCount == 0)
        #expect(!manager.hasTerminal(for: sessionId))

        await manager.resetForTesting()
    }

    @MainActor
    @Test
    func rootSurfaceUpdateContinuesForLiveSession() async {
        let manager = ConnectionSessionManager.shared
        await manager.resetForTesting()

        let session = ConnectionSession(
            serverId: UUID(),
            title: "Live Update",
            connectionState: .connected
        )
        manager.sessions = [session]

        // Given a root surface update arrives for a live session.
        let disposition = manager.prepareSurfaceForUpdate(
            sessionId: session.id,
            serverId: session.serverId,
            reason: "test live root update"
        )

        // Then the wrapper may continue UI-only update work.
        #expect(disposition == .continueUpdating)

        await manager.resetForTesting()
    }

    @MainActor
    @Test
    func rootSurfaceUpdateTracksClosedSessionCleanupUntilAwaited() async {
        let manager = ConnectionSessionManager.shared
        await manager.resetForTesting()

        let sessionId = UUID()
        let serverId = UUID()
        let recorder = TerminalSurfaceRegistryRecorder()
        manager.terminalSurfaceRegistry.registerForTesting(
            entityId: .session(sessionId),
            pause: { recorder.pauseCount += 1 },
            cleanup: { recorder.cleanupCount += 1 }
        )

        // Given a root surface update arrives after its session has already closed.
        let disposition = manager.prepareSurfaceForUpdate(
            sessionId: sessionId,
            serverId: serverId,
            reason: "test closed root update"
        )

        // Then cleanup is tracked as teardown work and is complete after awaiting it.
        #expect(disposition == .closedAndCleanedUp)
        await manager.waitForServerTeardownTasks(serverId)
        #expect(recorder.cleanupCount == 1)
        #expect(recorder.pauseCount == 0)
        #expect(!manager.hasTerminal(for: sessionId))

        await manager.resetForTesting()
    }

    @MainActor
    @Test
    func staleRootSurfaceEvictionDoesNotStartUnownedSSHUnregister() async {
        let manager = ConnectionSessionManager.shared
        await manager.resetForTesting()

        let unregisterRecorder = TerminalSSHUnregisterScheduleRecorder()
        manager.setSSHUnregisterScheduleOperationForTesting { sessionId in
            unregisterRecorder.record(sessionId)
        }

        let oldestSessionId = UUID()
        let oldestRecorder = TerminalSurfaceRegistryRecorder()
        manager.terminalSurfaceRegistry.registerForTesting(
            entityId: .session(oldestSessionId),
            pause: { oldestRecorder.pauseCount += 1 },
            cleanup: { oldestRecorder.cleanupCount += 1 }
        )

        for _ in 1..<20 {
            manager.terminalSurfaceRegistry.registerForTesting(
                entityId: .session(UUID()),
                pause: {},
                cleanup: {}
            )
        }

        // Given the LRU cache contains a stale root surface whose session no
        // longer has an application-layer owner.
        manager.evictOldTerminalsIfNeeded()

        // Then eviction releases the UI surface only and does not start an
        // untracked SSH unregister task that no server teardown owner can await.
        #expect(oldestRecorder.cleanupCount == 1)
        #expect(
            unregisterRecorder.scheduledSessionIds.isEmpty,
            "Stale surface eviction must not start SSH unregister without a server teardown owner."
        )
        #expect(manager.serverTeardownTaskStore.isEmpty)

        await manager.resetForTesting()
    }

    @MainActor
    @Test
    func splitViewDisappearancePreservesLivePaneSurfaceWithoutCleanup() async {
        let manager = TerminalTabManager.shared
        await manager.resetForTesting()

        let paneId = UUID()
        let tabId = UUID()
        let recorder = TerminalSurfaceRegistryRecorder()
        manager.paneStates[paneId] = TerminalPaneState(
            paneId: paneId,
            tabId: tabId,
            serverId: UUID()
        )
        manager.terminalSurfaceRegistry.registerForTesting(
            entityId: .pane(paneId),
            pause: { recorder.pauseCount += 1 },
            cleanup: { recorder.cleanupCount += 1 }
        )

        // Given a live split pane surface disappears because its view went away.
        let resolution = manager.handlePaneSurfaceViewDisappeared(paneId)

        // Then the manager preserves it for reuse and only pauses rendering.
        #expect(resolution == .preservedForReuse)
        #expect(recorder.pauseCount == 1)
        #expect(recorder.cleanupCount == 0)
        #expect(manager.terminalSurfaceRegistry.hasSurface(for: .pane(paneId)))

        await manager.resetForTesting()
    }

    @MainActor
    @Test
    func staleSplitViewDisappearanceDoesNotPauseReplacementSurface() async {
        let manager = TerminalTabManager.shared
        await manager.resetForTesting()

        let paneId = UUID()
        let tabId = UUID()
        let firstRecorder = TerminalSurfaceRegistryRecorder()
        let secondRecorder = TerminalSurfaceRegistryRecorder()
        manager.paneStates[paneId] = TerminalPaneState(
            paneId: paneId,
            tabId: tabId,
            serverId: UUID()
        )
        let staleSurfaceToken = manager.terminalSurfaceRegistry.registerForTesting(
            entityId: .pane(paneId),
            pause: { firstRecorder.pauseCount += 1 },
            cleanup: { firstRecorder.cleanupCount += 1 }
        )
        _ = manager.terminalSurfaceRegistry.registerForTesting(
            entityId: .pane(paneId),
            pause: { secondRecorder.pauseCount += 1 },
            cleanup: { secondRecorder.cleanupCount += 1 }
        )

        // Given SwiftUI has already replaced a live split-pane surface, and the
        // old representable is dismantled afterwards.
        let resolution = manager.handlePaneSurfaceViewDisappeared(
            paneId,
            surfaceToken: staleSurfaceToken
        )

        // Then stale pane teardown cannot pause or cleanup the replacement.
        #expect(resolution == .staleSurfaceIgnored)
        #expect(firstRecorder.cleanupCount == 1)
        #expect(secondRecorder.pauseCount == 0)
        #expect(secondRecorder.cleanupCount == 0)
        #expect(manager.terminalSurfaceRegistry.hasSurface(for: .pane(paneId)))

        await manager.resetForTesting()
    }

    @MainActor
    @Test
    func splitViewDisappearanceCleansClosedPaneSurface() async {
        let manager = TerminalTabManager.shared
        await manager.resetForTesting()

        let paneId = UUID()
        let recorder = TerminalSurfaceRegistryRecorder()
        manager.terminalSurfaceRegistry.registerForTesting(
            entityId: .pane(paneId),
            pause: { recorder.pauseCount += 1 },
            cleanup: { recorder.cleanupCount += 1 }
        )

        // Given a split pane surface disappears after its pane has already closed.
        let resolution = manager.handlePaneSurfaceViewDisappeared(paneId)

        // Then cleanup happens through the application manager, not the representable.
        #expect(resolution == .closedAndCleanedUp)
        #expect(recorder.cleanupCount == 1)
        #expect(recorder.pauseCount == 0)

        await manager.resetForTesting()
    }
}

private final class TerminalSurfaceTeardownRecorder: @unchecked Sendable {
    var enqueued = 0
    var freed = 0
    var operation: (@Sendable () -> Void)?
}

private final class TerminalSurfaceCallbackInvalidationRecorder: GhosttySurfaceCallbackInvalidating, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedEvents: [String] = []

    var events: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedEvents
    }

    func invalidate() {
        record("invalidate")
    }

    func record(_ event: String) {
        lock.lock()
        recordedEvents.append(event)
        lock.unlock()
    }
}

@MainActor
private final class TerminalSurfaceRegistryRecorder {
    var pauseCount = 0
    var cleanupCount = 0
    var runtimeTeardownCount = 0
}

private final class TerminalSSHUnregisterScheduleRecorder {
    private(set) var scheduledSessionIds: [UUID] = []

    func record(_ sessionId: UUID) {
        scheduledSessionIds.append(sessionId)
    }
}
