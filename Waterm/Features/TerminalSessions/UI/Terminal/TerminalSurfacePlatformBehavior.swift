import Foundation

#if os(macOS)
import AppKit
#endif

#if os(iOS)
import UIKit
#endif

@MainActor
extension GhosttyTerminalView {
    var isAttachedToPlatformWindow: Bool {
        window != nil
    }

    func pauseForClosedTerminalSurface(wasSelected: Bool) {
        pauseRendering()
        if !wasSelected {
            _ = resignFirstResponder()
        }
    }

    func requestInitialTerminalSurfaceFocus(isApplicationActive: Bool) {
        guard isAttachedToPlatformWindow else { return }

        #if os(iOS)
        guard isApplicationActive else { return }
        requestKeyboardFocus(for: .initialActivation)
        #else
        _ = window?.makeFirstResponder(self)
        #endif
    }

    func pauseForBackgroundTerminalSuspension() {
        pauseRendering()

        #if os(iOS)
        if isFirstResponder {
            markKeyboardFocusForReconnect()
        }
        _ = resignFirstResponder()
        #endif
    }
}
