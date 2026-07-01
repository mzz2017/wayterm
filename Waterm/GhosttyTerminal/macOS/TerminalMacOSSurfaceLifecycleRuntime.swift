//
//  TerminalMacOSSurfaceLifecycleRuntime.swift
//  Waterm
//
//  Runtime owner for macOS Ghostty surface lifecycle operations.
//

#if os(macOS)
import Foundation

@MainActor
final class TerminalMacOSSurfaceLifecycleRuntime {
    struct CleanupActions {
        let stopDisplayLink: () -> Void
        let cancelPendingZoomIndicatorHide: () -> Void
        let removeConfigReloadObserver: () -> Void
        let clearCallbacks: () -> Void
        let invalidateSurfaceCallbackContext: () -> Void
        let stopSurfaceInput: () -> Void
        let unregisterSurface: () -> Void
        let freeSurface: () -> Void
    }

    @discardableResult
    func cleanup(
        surface: Ghostty.Surface?,
        surfaceRegistration: GhosttySurfaceRegistration,
        stopDisplayLink: @escaping () -> Void,
        cancelPendingZoomIndicatorHide: @escaping () -> Void,
        removeConfigReloadObserver: @escaping () -> Void,
        clearCallbacks: @escaping () -> Void
    ) -> Ghostty.Surface? {
        performCleanup(
            actions: CleanupActions(
                stopDisplayLink: stopDisplayLink,
                cancelPendingZoomIndicatorHide: cancelPendingZoomIndicatorHide,
                removeConfigReloadObserver: removeConfigReloadObserver,
                clearCallbacks: clearCallbacks,
                invalidateSurfaceCallbackContext: {
                    surface?.invalidateCallbackContext()
                },
                stopSurfaceInput: {
                    Self.applyFocus(false, surface: surface)
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

    func setFocus(_ isFocused: Bool, surface: Ghostty.Surface?) {
        Self.applyFocus(isFocused, surface: surface)
    }

    func processExited(surface: Ghostty.Surface?) -> Bool {
        guard let surface = surface?.unsafeCValue else { return true }
        return ghostty_surface_process_exited(surface)
    }

    func performCleanup(actions: CleanupActions) {
        actions.stopDisplayLink()
        actions.cancelPendingZoomIndicatorHide()
        actions.removeConfigReloadObserver()
        actions.clearCallbacks()
        actions.invalidateSurfaceCallbackContext()
        actions.stopSurfaceInput()
        actions.unregisterSurface()
        actions.freeSurface()
    }

    private static func applyFocus(_ isFocused: Bool, surface: Ghostty.Surface?) {
        guard let surface = surface?.unsafeCValue else { return }
        ghostty_surface_set_focus(surface, isFocused)
    }
}

#endif
