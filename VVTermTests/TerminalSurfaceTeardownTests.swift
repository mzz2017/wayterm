import Foundation
import Testing
@testable import VVTerm

// Test Context:
// These tests protect terminal UI surface teardown rules. UI wrappers report
// disappeared surfaces; application-layer managers decide whether the surface is
// preserved for reuse or cleaned up because the entity closed.
// Target invariant: view disappearance pauses reusable surfaces without native
// teardown, while closed entities clean up exactly once and root closed-session
// cleanup remains tracked/awaitable through server teardown tasks.
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

@MainActor
private final class TerminalSurfaceRegistryRecorder {
    var pauseCount = 0
    var cleanupCount = 0
    var runtimeTeardownCount = 0
}
