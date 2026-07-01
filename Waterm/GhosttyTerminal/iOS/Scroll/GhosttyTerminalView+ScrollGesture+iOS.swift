#if os(iOS)
import UIKit

extension GhosttyTerminalView {
    // MARK: - Scroll Gesture

    func setNativeHostScrollContainerEnabled(_ enabled: Bool) {
        isNativeHostScrollContainerEnabled = enabled
        if enabled {
            scrollRuntime.stopMomentumScrolling()
        }
    }

    func prepareForNativeHostScroll() {
        scrollRuntime.prepareForNativeHostScroll()
    }

    func currentScrollOwner() -> TerminalScrollOwner {
        TerminalScrollRoutingPolicy.owner(for: TerminalScrollContext(
            remoteScrollOwnerActive: surfaceOwner.isMouseCaptured,
            remoteAlternateScreenActive: surfaceOwner.isInAlternateScreen,
            hasHostScrollableRows: hasHostScrollableRows,
            isSelecting: isTerminalSelectionActive,
            isPinching: zoomRuntime.isPinchingTerminalZoom
        ))
    }

    private var hasHostScrollableRows: Bool {
        guard let scrollbar else { return false }
        return scrollbar.total > scrollbar.len
    }

    @objc func handlePanGesture(_ recognizer: UIPanGestureRecognizer) {
        guard surfaceOwner.hasLiveSurface else { return }
        if isNativeHostScrollContainerEnabled,
           currentScrollOwner() == .hostScrollback {
            return
        }
        if isSelecting { return }
        if zoomRuntime.isPinchingTerminalZoom { return }
        if touchSelectionState.hasSelection {
            if recognizer.state == .began,
               !isPointOnTouchSelectionHandle(recognizer.location(in: self)) {
                clearTouchSelection()
            }
            return
        }

        scrollRuntime.handlePanGesture(
            recognizer,
            in: self,
            mapLocation: { [weak self] location in
                self?.ghosttyPoint(location) ?? location
            },
            hasSurface: { [weak self] in
                self?.surfaceOwner.hasLiveSurface ?? false
            },
            sendMousePosition: { [weak self] position in
                self?.surfaceOwner.sendMousePosition(position)
            },
            sendScrollEvent: { [weak self] event in
                self?.surfaceOwner.sendMouseScroll(event)
            },
            requestRender: { [weak self] in
                self?.requestRender()
            }
        )
    }
}
#endif
