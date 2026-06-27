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
        surface?.sendText(text)
    }

    @discardableResult
    func perform(action: String) -> Bool {
        surface?.perform(action: action) ?? false
    }

    func sendKeyPress(_ key: Ghostty.Input.Key) {
        surface?.sendKeyEvent(.init(key: key, action: .press))
        surface?.sendKeyEvent(.init(key: key, action: .release))
    }

    func sendModifiedKey(
        _ key: Ghostty.Input.Key,
        mods: Ghostty.Input.Mods,
        text: String?,
        unshiftedCodepoint: UInt32
    ) {
        let press = Ghostty.Input.KeyEvent(
            key: key,
            action: .press,
            text: text,
            composing: false,
            mods: mods,
            consumedMods: [],
            unshiftedCodepoint: unshiftedCodepoint
        )
        surface?.sendKeyEvent(press)
        let release = Ghostty.Input.KeyEvent(
            key: key,
            action: .release,
            text: nil,
            composing: false,
            mods: mods,
            consumedMods: [],
            unshiftedCodepoint: unshiftedCodepoint
        )
        surface?.sendKeyEvent(release)
    }

    func sendKeyEvent(_ event: Ghostty.Input.KeyEvent) {
        surface?.sendKeyEvent(event)
    }

    func sendMousePosition(_ position: CGPoint) {
        surface?.sendMousePos(.init(x: position.x, y: position.y, mods: []))
    }

    func sendMouseScroll(_ event: Ghostty.Input.MouseScrollEvent) {
        surface?.sendMouseScroll(event)
    }

    func sendDirectHardwareKeyEvent(
        _ key: UIKey,
        action: ghostty_input_action_e,
        using inputRuntime: TerminalIOSInputRuntime
    ) -> Bool {
        guard let cSurface = surface?.unsafeCValue else { return false }
        return inputRuntime.sendDirectHardwareKeyEvent(key, action: action, surface: cSurface)
    }

    func syncVisiblePreedit(
        _ text: String?,
        inputModePrimaryLanguage: String?,
        using inputRuntime: TerminalIOSInputRuntime
    ) -> Bool {
        inputRuntime.syncVisiblePreedit(
            text,
            inputModePrimaryLanguage: inputModePrimaryLanguage,
            surface: surface?.unsafeCValue
        )
    }

    func imePoint(using inputRuntime: TerminalIOSInputRuntime) -> CGRect? {
        guard let cSurface = surface?.unsafeCValue else { return nil }
        return inputRuntime.imePoint(surface: cSurface)
    }
}
#endif
