#if os(iOS)
import Foundation

@MainActor
final class TerminalIOSSurfaceLifecycleRuntime {
    struct CleanupActions {
        let stopMomentumScrolling: () -> Void
        let cancelPendingZoomIndicatorHide: () -> Void
        let invalidateLifecycleObservers: () -> Void
        let clearCallbacks: () -> Void
        let invalidateSurfaceCallbackContext: () -> Void
        let stopSurfaceInputAndRendering: () -> Void
        let unregisterSurface: () -> Void
        let freeSurface: () -> Void
    }

    struct PauseActions {
        let clearFocus: () -> Void
        let setOcclusion: (Bool) -> Void
    }

    struct ResumeActions {
        let setOcclusion: (Bool) -> Void
        let updateSizeAndRequestRender: () -> Void
    }

    @discardableResult
    func cleanup(
        surface: Ghostty.Surface?,
        surfaceRegistration: GhosttySurfaceRegistration,
        stopMomentumScrolling: @escaping () -> Void,
        cancelPendingZoomIndicatorHide: @escaping () -> Void,
        invalidateLifecycleObservers: @escaping () -> Void,
        clearCallbacks: @escaping () -> Void
    ) -> Ghostty.Surface? {
        performCleanup(
            actions: CleanupActions(
                stopMomentumScrolling: stopMomentumScrolling,
                cancelPendingZoomIndicatorHide: cancelPendingZoomIndicatorHide,
                invalidateLifecycleObservers: invalidateLifecycleObservers,
                clearCallbacks: clearCallbacks,
                invalidateSurfaceCallbackContext: {
                    surface?.invalidateCallbackContext()
                },
                stopSurfaceInputAndRendering: {
                    Self.stopSurfaceInputAndRendering(surface)
                },
                unregisterSurface: {
                    surfaceRegistration.unregister()
                },
                freeSurface: {
                    surface?.free()
                }
            )
        )
        return nil
    }

    func pauseRendering(surface: Ghostty.Surface?) {
        performPause(
            actions: PauseActions(
                clearFocus: {
                    Self.setFocus(false, surface: surface)
                },
                setOcclusion: { isVisible in
                    Self.setOcclusion(isVisible, surface: surface)
                }
            )
        )
    }

    func resumeRendering(surface: Ghostty.Surface?, updateSizeAndRequestRender: @escaping () -> Void) {
        performResume(
            actions: ResumeActions(
                setOcclusion: { isVisible in
                    Self.setOcclusion(isVisible, surface: surface)
                },
                updateSizeAndRequestRender: updateSizeAndRequestRender
            )
        )
    }

    func performCleanup(actions: CleanupActions) {
        actions.stopMomentumScrolling()
        actions.cancelPendingZoomIndicatorHide()
        actions.invalidateLifecycleObservers()
        actions.clearCallbacks()
        actions.invalidateSurfaceCallbackContext()
        actions.stopSurfaceInputAndRendering()
        actions.unregisterSurface()
        actions.freeSurface()
    }

    func performPause(actions: PauseActions) {
        actions.clearFocus()
        actions.setOcclusion(false)
    }

    func performResume(actions: ResumeActions) {
        actions.setOcclusion(true)
        actions.updateSizeAndRequestRender()
    }

    private static func stopSurfaceInputAndRendering(_ surface: Ghostty.Surface?) {
        setFocus(false, surface: surface)
        setOcclusion(false, surface: surface)
    }

    private static func setFocus(_ isFocused: Bool, surface: Ghostty.Surface?) {
        guard let surface = surface?.unsafeCValue else { return }
        ghostty_surface_set_focus(surface, isFocused)
    }

    private static func setOcclusion(_ isVisible: Bool, surface: Ghostty.Surface?) {
        guard let surface = surface?.unsafeCValue else { return }
        ghostty_surface_set_occlusion(surface, isVisible)
    }
}
#endif
