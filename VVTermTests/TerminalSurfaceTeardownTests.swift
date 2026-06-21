import Foundation
import Testing
@testable import VVTerm

// Test Context:
// These tests protect terminal UI surface teardown rules. A terminal surface can
// be detached or cleaned up by SwiftUI/AppKit/UIKit lifecycle, but SSH shell and
// client teardown must remain owned by application-layer connection managers.
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
