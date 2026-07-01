#if os(iOS)
import UIKit

extension GhosttyTerminalView {
    // MARK: - Zoom Gesture

    @objc func handlePinchGesture(_ recognizer: UIPinchGestureRecognizer) {
        zoomRuntime.handlePinchGesture(
            recognizer,
            canHandlePinchZoom: canHandlePinchZoom,
            currentFontSize: { [weak self] in
                self?.surfacePresentationOverrides.resolvedFontSize() ?? TerminalDefaults.storedFontSize()
            },
            performZoomAction: onZoomAction,
            stopMomentumScrolling: { [weak self] in
                self?.scrollRuntime.stopMomentumScrolling()
            },
            requestIndicatorLayout: { [weak self] in
                self?.setNeedsLayout()
                self?.layoutIfNeeded()
                if let self {
                    self.zoomRuntime.bringIndicatorToFront(in: self)
                }
            }
        )
    }

    var canHandlePinchZoom: Bool {
        if usesNativeTouchSelection, nativeSelectionInteractionActive || nativeSelectedRange != nil {
            return false
        }
        if usesAppOwnedTouchSelection, touchSelectionState.hasSelection {
            return false
        }
        return true
    }
}
#endif
