//
//  TerminalIOSSurfaceOwner.swift
//  VVTerm
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
    var surface: Ghostty.Surface?
    private let surfaceInputRuntime = TerminalIOSSurfaceInputRuntime()

    init(ghosttyApp: ghostty_app_t, appWrapper: Ghostty.App?) {
        self.ghosttyApp = ghosttyApp
        self.appWrapper = appWrapper
    }

    var hasLiveSurface: Bool {
        surface?.unsafeCValue != nil
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
        using lifecycleRuntime: TerminalIOSSurfaceLifecycleRuntime,
        surfaceRegistration: GhosttySurfaceRegistration,
        stopMomentumScrolling: @escaping () -> Void,
        cancelPendingZoomIndicatorHide: @escaping () -> Void,
        invalidateLifecycleObservers: @escaping () -> Void,
        clearCallbacks: @escaping () -> Void
    ) {
        surface = lifecycleRuntime.cleanup(
            surface: surface,
            surfaceRegistration: surfaceRegistration,
            stopMomentumScrolling: stopMomentumScrolling,
            cancelPendingZoomIndicatorHide: cancelPendingZoomIndicatorHide,
            invalidateLifecycleObservers: invalidateLifecycleObservers,
            clearCallbacks: clearCallbacks
        )
    }

    func pauseRendering(using lifecycleRuntime: TerminalIOSSurfaceLifecycleRuntime) {
        lifecycleRuntime.pauseRendering(surface: surface)
    }

    func resumeRendering(
        using lifecycleRuntime: TerminalIOSSurfaceLifecycleRuntime,
        updateSizeAndRequestRender: @escaping () -> Void
    ) {
        lifecycleRuntime.resumeRendering(surface: surface, updateSizeAndRequestRender: updateSizeAndRequestRender)
    }

    func setFocus(_ isFocused: Bool, using lifecycleRuntime: TerminalIOSSurfaceLifecycleRuntime) {
        lifecycleRuntime.setFocus(isFocused, surface: surface)
    }

    func setOcclusion(_ isVisible: Bool, using lifecycleRuntime: TerminalIOSSurfaceLifecycleRuntime) {
        lifecycleRuntime.setOcclusion(isVisible, surface: surface)
    }

    func processExited(using lifecycleRuntime: TerminalIOSSurfaceLifecycleRuntime) -> Bool {
        lifecycleRuntime.processExited(surface: surface)
    }

    var needsConfirmQuit: Bool {
        surface?.needsConfirmQuit ?? false
    }

    func terminalSize() -> Ghostty.Surface.TerminalSize? {
        surface?.terminalSize()
    }

    func resizeIfNeeded(
        pointSize: CGSize,
        scale: CGFloat,
        using displayRuntime: TerminalIOSSurfaceDisplayRuntime
    ) -> Bool {
        guard let cSurface = surface?.unsafeCValue else { return false }
        return displayRuntime.resizeIfNeeded(surface: cSurface, pointSize: pointSize, scale: scale)
    }

    func forceResize(
        pointSize: CGSize,
        scale: CGFloat,
        using displayRuntime: TerminalIOSSurfaceDisplayRuntime
    ) -> Bool {
        guard let cSurface = surface?.unsafeCValue else { return false }
        return displayRuntime.forceResize(surface: cSurface, pointSize: pointSize, scale: scale)
    }

    func setOcclusion(_ isVisible: Bool, using displayRuntime: TerminalIOSSurfaceDisplayRuntime) {
        guard let cSurface = surface?.unsafeCValue else { return }
        displayRuntime.setOcclusion(isVisible, surface: cSurface)
    }

    func setColorScheme(
        _ scheme: ghostty_color_scheme_e,
        using displayRuntime: TerminalIOSSurfaceDisplayRuntime
    ) {
        guard let cSurface = surface?.unsafeCValue else { return }
        displayRuntime.setColorScheme(scheme, surface: cSurface)
    }

    func redraw(using displayRuntime: TerminalIOSSurfaceDisplayRuntime) {
        guard let cSurface = surface?.unsafeCValue else { return }
        displayRuntime.redraw(surface: cSurface)
    }

    @discardableResult
    func updateSurfaceConfig(_ presentationOverrides: TerminalPresentationOverrides) -> Bool {
        guard let cSurface = surface?.unsafeCValue else { return false }
        appWrapper?.updateSurfaceConfig(cSurface, presentationOverrides: presentationOverrides)
        return true
    }

    func writeOutput(_ data: Data, using displayRuntime: TerminalIOSSurfaceDisplayRuntime) {
        guard let cSurface = surface?.unsafeCValue else { return }
        displayRuntime.writeOutput(data, to: cSurface)
    }

    func externalExited(_ exitCode: UInt32, using displayRuntime: TerminalIOSSurfaceDisplayRuntime) {
        guard let cSurface = surface?.unsafeCValue else { return }
        displayRuntime.externalExited(exitCode, surface: cSurface)
    }

    func hasGhosttySelection(using selectionRuntime: TerminalIOSSelectionRuntime) -> Bool {
        selectionRuntime.hasGhosttySelection(surface: surface?.unsafeCValue)
    }

    func nativeTextSnapshot(
        metrics: TerminalSelectionGridMetrics?,
        using selectionRuntime: TerminalIOSSelectionRuntime
    ) -> TerminalNativeTextSnapshot {
        selectionRuntime.nativeTextSnapshot(surface: surface?.unsafeCValue, metrics: metrics)
    }

    func quickLookWordSelection(
        at point: CGPoint,
        layout: TerminalTouchSelectionLayout,
        using selectionRuntime: TerminalIOSSelectionRuntime
    ) -> TerminalGridSelection? {
        surface?.sendMousePos(.init(x: point.x, y: point.y, mods: []))
        return selectionRuntime.quickLookWordSelection(surface: surface?.unsafeCValue, layout: layout)
    }

    func touchSelectionText(
        _ selection: TerminalGridSelection,
        using selectionRuntime: TerminalIOSSelectionRuntime
    ) -> String? {
        selectionRuntime.touchSelectionText(surface: surface?.unsafeCValue, selection: selection)
    }

    func ghosttySelectionText(using selectionRuntime: TerminalIOSSelectionRuntime) -> String? {
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
