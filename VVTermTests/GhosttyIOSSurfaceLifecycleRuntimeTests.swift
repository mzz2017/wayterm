#if os(iOS)
import Foundation
import Testing
@testable import VVTerm

// Test Context:
// Protects iOS Ghostty surface lifecycle ownership. GhosttyTerminalView may
// request cleanup, pause, and resume, but TerminalIOSSurfaceLifecycleRuntime
// owns the teardown ordering and direct surface lifecycle FFI. Update these
// tests only when that ownership boundary intentionally changes.
@Suite(.serialized)
@MainActor
struct GhosttyIOSSurfaceLifecycleRuntimeTests {
    @Test
    func iOSTerminalViewDelegatesSurfaceLifecycleFFIAndTeardownToRuntimeOwner() throws {
        let root = try sourceRoot()
        let viewSource = try source(
            at: root.appendingPathComponent("VVTerm/GhosttyTerminal/iOS/View/GhosttyTerminalView+iOS.swift")
        )
        let surfaceRuntimeSource = try source(
            at: root.appendingPathComponent("VVTerm/GhosttyTerminal/iOS/Surface/GhosttyTerminalView+SurfaceRuntime+iOS.swift")
        )
        let ownerSource = try source(
            at: root.appendingPathComponent("VVTerm/GhosttyTerminal/iOS/Surface/TerminalIOSSurfaceOwner.swift")
        )
        let runtimeSource = try source(
            at: root.appendingPathComponent("VVTerm/GhosttyTerminal/iOS/Surface/TerminalIOSSurfaceLifecycleRuntime.swift")
        )

        let cleanupSource = try section(in: surfaceRuntimeSource, from: "func cleanup()", to: "/// Pause rendering")
        let pauseSource = try section(in: surfaceRuntimeSource, from: "func pauseRendering()", to: "/// Resume rendering")
        let resumeSource = try section(in: surfaceRuntimeSource, from: "func resumeRendering()", to: "private func clearLifecycleCallbacks")
        let lifecycleCallSource = viewSource + surfaceRuntimeSource

        #expect(viewSource.contains("let surfaceLifecycleRuntime = TerminalIOSSurfaceLifecycleRuntime()"))
        #expect(cleanupSource.contains("using: surfaceLifecycleRuntime"))
        #expect(pauseSource.contains("using: surfaceLifecycleRuntime"))
        #expect(resumeSource.contains("using: surfaceLifecycleRuntime"))
        #expect(ownerSource.contains("lifecycleRuntime.cleanup("))
        #expect(ownerSource.contains("lifecycleRuntime.pauseRendering("))
        #expect(ownerSource.contains("lifecycleRuntime.resumeRendering("))
        #expect(ownerSource.contains("lifecycleRuntime.setFocus("))
        #expect(ownerSource.contains("lifecycleRuntime.setOcclusion("))
        #expect(ownerSource.contains("lifecycleRuntime.processExited(surface: surface)"))

        #expect(!lifecycleCallSource.contains("ghostty_surface_set_focus"))
        #expect(!lifecycleCallSource.contains("ghostty_surface_set_occlusion"))
        #expect(!lifecycleCallSource.contains("ghostty_surface_process_exited"))
        #expect(!cleanupSource.contains("ghostty_surface_set_focus"))
        #expect(!cleanupSource.contains("ghostty_surface_set_occlusion"))
        #expect(!cleanupSource.contains("surfaceRegistration.unregister()"))
        #expect(!cleanupSource.contains("surface?.free()"))
        #expect(!pauseSource.contains("ghostty_surface_set_focus"))
        #expect(!pauseSource.contains("ghostty_surface_set_occlusion"))
        #expect(!resumeSource.contains("ghostty_surface_set_occlusion"))

        #expect(runtimeSource.contains("final class TerminalIOSSurfaceLifecycleRuntime"))
        #expect(runtimeSource.contains("ghostty_surface_set_focus"))
        #expect(runtimeSource.contains("ghostty_surface_set_occlusion"))
        #expect(runtimeSource.contains("ghostty_surface_process_exited"))
        #expect(runtimeSource.contains("surfaceRegistration.unregister()"))
        #expect(runtimeSource.contains("surface?.free()"))
    }

    @Test
    func cleanupRunsTeardownActionsInCallbackSafeOrder() {
        let runtime = TerminalIOSSurfaceLifecycleRuntime()
        var events: [String] = []

        // Given a live iOS surface with callbacks, observers, registration, and native resources.
        runtime.performCleanup(
            actions: TerminalIOSSurfaceLifecycleRuntime.CleanupActions(
                stopMomentumScrolling: { events.append("stopMomentum") },
                cancelPendingZoomIndicatorHide: { events.append("cancelZoom") },
                invalidateLifecycleObservers: { events.append("invalidateObservers") },
                clearCallbacks: { events.append("clearCallbacks") },
                invalidateSurfaceCallbackContext: { events.append("invalidateSurfaceCallbackContext") },
                stopSurfaceInputAndRendering: { events.append("stopSurfaceInputAndRendering") },
                unregisterSurface: { events.append("unregisterSurface") },
                freeSurface: { events.append("freeSurface") }
            )
        )

        // Then callbacks and callback context are disabled before FFI visibility,
        // registration, and native resource release.
        #expect(
            events == [
                "stopMomentum",
                "cancelZoom",
                "invalidateObservers",
                "clearCallbacks",
                "invalidateSurfaceCallbackContext",
                "stopSurfaceInputAndRendering",
                "unregisterSurface",
                "freeSurface"
            ],
            "Surface cleanup must prevent callbacks before unregistering or freeing native resources."
        )
    }

    @Test
    func pauseClearsFocusBeforeMarkingSurfaceOccluded() {
        let runtime = TerminalIOSSurfaceLifecycleRuntime()
        var events: [String] = []

        // Given a visible iOS surface being paused.
        runtime.performPause(
            actions: TerminalIOSSurfaceLifecycleRuntime.PauseActions(
                clearFocus: { events.append("clearFocus") },
                setOcclusion: { isVisible in events.append("occlusion-\(isVisible)") }
            )
        )

        // Then input focus is removed before rendering is marked hidden.
        #expect(
            events == ["clearFocus", "occlusion-false"],
            "Pause should stop surface input before marking the surface occluded."
        )
    }

    @Test
    func resumeMarksSurfaceVisibleBeforeLayoutAndRenderRequest() {
        let runtime = TerminalIOSSurfaceLifecycleRuntime()
        var events: [String] = []

        // Given a paused iOS surface being resumed.
        runtime.performResume(
            actions: TerminalIOSSurfaceLifecycleRuntime.ResumeActions(
                setOcclusion: { isVisible in events.append("occlusion-\(isVisible)") },
                updateSizeAndRequestRender: { events.append("updateSizeAndRequestRender") }
            )
        )

        // Then Ghostty sees the surface as visible before resize/render work is requested.
        #expect(
            events == ["occlusion-true", "updateSizeAndRequestRender"],
            "Resume should mark the surface visible before asking Ghostty to size and render it."
        )
    }

    private func source(at url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    private func section(in source: String, from start: String, to end: String) throws -> String {
        guard let startRange = source.range(of: start),
              let endRange = source[startRange.upperBound...].range(of: end) else {
            throw SourceRootError.notFound
        }
        return String(source[startRange.lowerBound..<endRange.lowerBound])
    }

    private func sourceRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.lastPathComponent != "VVTermTests" {
            let next = url.deletingLastPathComponent()
            if next.path == url.path {
                throw SourceRootError.notFound
            }
            url = next
        }
        return url.deletingLastPathComponent()
    }

    private enum SourceRootError: Error {
        case notFound
    }
}
#endif
