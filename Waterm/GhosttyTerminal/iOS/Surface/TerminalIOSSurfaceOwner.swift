//
//  TerminalIOSSurfaceOwner.swift
//  Waterm
//
//  Stable owner for iOS Ghostty app and surface references.
//

#if os(iOS)
import Foundation
import UIKit

@MainActor
final class TerminalIOSSurfaceOwner {
    let ghosttyApp: ghostty_app_t
    weak var appWrapper: Ghostty.App?
    private var surface: Ghostty.Surface?
    private let surfaceDisplayRuntime: TerminalIOSSurfaceDisplayRuntime
    private let surfaceLifecycleRuntime: TerminalIOSSurfaceLifecycleRuntime
    private let surfaceInputRuntime: TerminalIOSSurfaceInputRuntime
    private let selectionRuntime: TerminalIOSSelectionRuntime

    init(
        ghosttyApp: ghostty_app_t,
        appWrapper: Ghostty.App?,
        surfaceDisplayRuntime: TerminalIOSSurfaceDisplayRuntime? = nil,
        surfaceLifecycleRuntime: TerminalIOSSurfaceLifecycleRuntime? = nil,
        surfaceInputRuntime: TerminalIOSSurfaceInputRuntime? = nil,
        selectionRuntime: TerminalIOSSelectionRuntime? = nil
    ) {
        self.ghosttyApp = ghosttyApp
        self.appWrapper = appWrapper
        self.surfaceDisplayRuntime = surfaceDisplayRuntime ?? TerminalIOSSurfaceDisplayRuntime()
        self.surfaceLifecycleRuntime = surfaceLifecycleRuntime ?? TerminalIOSSurfaceLifecycleRuntime()
        self.surfaceInputRuntime = surfaceInputRuntime ?? TerminalIOSSurfaceInputRuntime()
        self.selectionRuntime = selectionRuntime ?? TerminalIOSSelectionRuntime()
    }

    var hasLiveSurface: Bool {
        surface?.unsafeCValue != nil
    }

    var liveSurfaceHandle: ghostty_surface_t? {
        surface?.unsafeCValue
    }

    var isMouseCaptured: Bool {
        surface?.mouseCaptured ?? false
    }

    var isInAlternateScreen: Bool {
        surface?.inAlternateScreen ?? false
    }

    @discardableResult
    func createAndRegisterSurface(
        using renderingSetup: GhosttyRenderingSetup,
        terminalView: GhosttyTerminalView,
        worktreePath: String,
        initialBounds: CGRect,
        surfaceCallbackContext: GhosttySurfaceCallbackContext,
        paneId: String?,
        command: String?,
        useCustomIO: Bool,
        surfaceRegistration: GhosttySurfaceRegistration,
        configureSurfaceLayers: () -> Void
    ) -> Bool {
        guard let cSurface = renderingSetup.setupSurface(
            view: terminalView,
            ghosttyApp: ghosttyApp,
            worktreePath: worktreePath,
            initialBounds: initialBounds,
            surfaceCallbackContext: surfaceCallbackContext,
            paneId: paneId,
            command: command,
            useCustomIO: useCustomIO
        ) else {
            return false
        }

        configureSurfaceLayers()
        surface = Ghostty.Surface(cSurface: cSurface, callbackContext: surfaceCallbackContext)
        surfaceRegistration.register(cSurface, appWrapper: appWrapper, terminalView: terminalView)
        return true
    }

    func cleanup(
        surfaceRegistration: GhosttySurfaceRegistration,
        stopMomentumScrolling: @escaping () -> Void,
        cancelPendingZoomIndicatorHide: @escaping () -> Void,
        invalidateLifecycleObservers: @escaping () -> Void,
        clearCallbacks: @escaping () -> Void
    ) {
        surface = surfaceLifecycleRuntime.cleanup(
            surface: surface,
            surfaceRegistration: surfaceRegistration,
            stopMomentumScrolling: stopMomentumScrolling,
            cancelPendingZoomIndicatorHide: cancelPendingZoomIndicatorHide,
            invalidateLifecycleObservers: invalidateLifecycleObservers,
            clearCallbacks: clearCallbacks
        )
    }

    func pauseRendering() {
        surfaceLifecycleRuntime.pauseRendering(surface: surface)
    }

    func resumeRendering(
        updateSizeAndRequestRender: @escaping () -> Void
    ) {
        surfaceLifecycleRuntime.resumeRendering(surface: surface, updateSizeAndRequestRender: updateSizeAndRequestRender)
    }

    func setFocus(_ isFocused: Bool) {
        surfaceLifecycleRuntime.setFocus(isFocused, surface: surface)
    }

    func setOcclusion(_ isVisible: Bool) {
        surfaceLifecycleRuntime.setOcclusion(isVisible, surface: surface)
    }

    func processExited() -> Bool {
        surfaceLifecycleRuntime.processExited(surface: surface)
    }

    var needsConfirmQuit: Bool {
        surface?.needsConfirmQuit ?? false
    }

    func terminalSize() -> Ghostty.Surface.TerminalSize? {
        surface?.terminalSize()
    }

    func resizeIfNeeded(
        pointSize: CGSize,
        scale: CGFloat
    ) -> Bool {
        guard let cSurface = surface?.unsafeCValue else { return false }
        return surfaceDisplayRuntime.resizeIfNeeded(surface: cSurface, pointSize: pointSize, scale: scale)
    }

    func forceResize(
        pointSize: CGSize,
        scale: CGFloat
    ) -> Bool {
        guard let cSurface = surface?.unsafeCValue else { return false }
        return surfaceDisplayRuntime.forceResize(surface: cSurface, pointSize: pointSize, scale: scale)
    }

    func setColorScheme(
        _ scheme: ghostty_color_scheme_e
    ) {
        guard let cSurface = surface?.unsafeCValue else { return }
        surfaceDisplayRuntime.setColorScheme(scheme, surface: cSurface)
    }

    func redraw() {
        guard let cSurface = surface?.unsafeCValue else { return }
        surfaceDisplayRuntime.redraw(surface: cSurface)
    }

    func resetDisplaySizeTracking() {
        surfaceDisplayRuntime.resetSizeTracking()
    }

    @discardableResult
    func updateSurfaceConfig(_ presentationOverrides: TerminalPresentationOverrides) -> Bool {
        guard let cSurface = surface?.unsafeCValue else { return false }
        appWrapper?.updateSurfaceConfig(cSurface, presentationOverrides: presentationOverrides)
        return true
    }

    func writeOutput(_ data: Data) {
        guard let cSurface = surface?.unsafeCValue else { return }
        surfaceDisplayRuntime.writeOutput(data, to: cSurface)
    }

    func externalExited(_ exitCode: UInt32) {
        guard let cSurface = surface?.unsafeCValue else { return }
        surfaceDisplayRuntime.externalExited(exitCode, surface: cSurface)
    }

    func hasGhosttySelection() -> Bool {
        selectionRuntime.hasGhosttySelection(surface: surface?.unsafeCValue)
    }

    func nativeTextSnapshot(
        metrics: TerminalSelectionGridMetrics?
    ) -> TerminalNativeTextSnapshot {
        selectionRuntime.nativeTextSnapshot(surface: surface?.unsafeCValue, metrics: metrics)
    }

    func quickLookWordSelection(
        at point: CGPoint,
        layout: TerminalTouchSelectionLayout
    ) -> TerminalGridSelection? {
        selectionRuntime.quickLookWordSelection(
            at: point,
            surface: surface?.unsafeCValue,
            layout: layout
        )
    }

    func touchSelectionText(
        _ selection: TerminalGridSelection
    ) -> String? {
        selectionRuntime.touchSelectionText(surface: surface?.unsafeCValue, selection: selection)
    }

    func ghosttySelectionText() -> String? {
        selectionRuntime.ghosttySelectionText(surface: surface?.unsafeCValue)
    }

    func sendText(_ text: String) {
        surfaceInputRuntime.sendText(text, surface: surface)
    }

    @discardableResult
    func perform(action: String) -> Bool {
        surfaceInputRuntime.perform(action: action, surface: surface)
    }

    func sendKeyPress(
        _ key: Ghostty.Input.Key,
        using inputRuntime: TerminalIOSInputRuntime
    ) {
        surfaceInputRuntime.sendKeyPress(key, surface: surface, using: inputRuntime)
    }

    func sendModifiedKey(
        _ key: Ghostty.Input.Key,
        mods: Ghostty.Input.Mods,
        text: String?,
        unshiftedCodepoint: UInt32,
        using inputRuntime: TerminalIOSInputRuntime
    ) {
        surfaceInputRuntime.sendModifiedKey(
            key,
            mods: mods,
            text: text,
            unshiftedCodepoint: unshiftedCodepoint,
            surface: surface,
            using: inputRuntime
        )
    }

    func sendKeyEvent(_ event: Ghostty.Input.KeyEvent) {
        surfaceInputRuntime.sendKeyEvent(event, surface: surface)
    }

    func sendMousePosition(_ position: CGPoint) {
        surfaceInputRuntime.sendMousePosition(position, surface: surface)
    }

    func sendMouseButton(_ event: Ghostty.Input.MouseButtonEvent) {
        surfaceInputRuntime.sendMouseButton(event, surface: surface)
    }

    func sendMouseScroll(_ event: Ghostty.Input.MouseScrollEvent) {
        surfaceInputRuntime.sendMouseScroll(event, surface: surface)
    }

    func sendDirectHardwareKeyEvent(
        _ key: UIKey,
        action: ghostty_input_action_e,
        using inputRuntime: TerminalIOSInputRuntime
    ) -> Bool {
        surfaceInputRuntime.sendDirectHardwareKeyEvent(key, action: action, surface: surface, using: inputRuntime)
    }

    func syncVisiblePreedit(
        _ text: String?,
        inputModePrimaryLanguage: String?,
        using inputRuntime: TerminalIOSInputRuntime
    ) -> Bool {
        surfaceInputRuntime.syncVisiblePreedit(
            text,
            inputModePrimaryLanguage: inputModePrimaryLanguage,
            surface: surface,
            using: inputRuntime
        )
    }

    func imePoint(using inputRuntime: TerminalIOSInputRuntime) -> CGRect? {
        surfaceInputRuntime.imePoint(surface: surface, using: inputRuntime)
    }
}
#endif
