#if os(iOS)
import UIKit

@MainActor
final class TerminalIOSZoomRuntime {
    typealias CurrentFontSize = @MainActor @Sendable () -> Double
    typealias PerformZoomAction = @MainActor @Sendable (TerminalZoomAction) -> TerminalZoomResult?
    typealias StopMomentumScrolling = @MainActor @Sendable () -> Void
    typealias RequestIndicatorLayout = @MainActor @Sendable () -> Void

    private var isPinching = false
    private var pinchReferenceScale: CGFloat = 1
    private let indicatorView = TerminalZoomIndicatorView()
    private var indicatorHideWorkItem: DispatchWorkItem?

    var isPinchingTerminalZoom: Bool {
        isPinching
    }

    deinit {
        indicatorHideWorkItem?.cancel()
    }

    func installIndicator(in containerView: UIView) {
        indicatorView.isHidden = true
        indicatorView.alpha = 0
        indicatorView.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(indicatorView)
        NSLayoutConstraint.activate([
            indicatorView.centerXAnchor.constraint(equalTo: containerView.centerXAnchor),
            indicatorView.centerYAnchor.constraint(equalTo: containerView.centerYAnchor),
            indicatorView.widthAnchor.constraint(greaterThanOrEqualToConstant: TerminalZoomPresentation.indicatorMinimumWidth),
            indicatorView.heightAnchor.constraint(greaterThanOrEqualToConstant: TerminalZoomPresentation.indicatorMinimumHeight)
        ])
    }

    func bringIndicatorToFront(in containerView: UIView) {
        containerView.bringSubviewToFront(indicatorView)
    }

    func cancelPendingIndicatorHide() {
        indicatorHideWorkItem?.cancel()
        indicatorHideWorkItem = nil
    }

    func handlePinchGesture(
        _ recognizer: UIPinchGestureRecognizer,
        canHandlePinchZoom: Bool,
        currentFontSize: CurrentFontSize,
        performZoomAction: PerformZoomAction?,
        stopMomentumScrolling: StopMomentumScrolling,
        requestIndicatorLayout: RequestIndicatorLayout
    ) {
        handlePinchGestureState(
            recognizer.state,
            scale: recognizer.scale,
            canHandlePinchZoom: canHandlePinchZoom,
            currentFontSize: currentFontSize,
            performZoomAction: performZoomAction,
            stopMomentumScrolling: stopMomentumScrolling,
            requestIndicatorLayout: requestIndicatorLayout
        )
    }

    func handlePinchGestureState(
        _ state: UIGestureRecognizer.State,
        scale: CGFloat,
        canHandlePinchZoom: Bool,
        currentFontSize: CurrentFontSize,
        performZoomAction: PerformZoomAction?,
        stopMomentumScrolling: StopMomentumScrolling,
        requestIndicatorLayout: RequestIndicatorLayout
    ) {
        guard canHandlePinchZoom else {
            isPinching = false
            return
        }

        switch state {
        case .began:
            isPinching = true
            pinchReferenceScale = scale
            stopMomentumScrolling()
            showIndicator(fontSize: currentFontSize(), requestLayout: requestIndicatorLayout)
        case .changed:
            guard isPinching else { return }
            let relativeScale = scale / pinchReferenceScale
            if relativeScale >= CGFloat(TerminalZoomPresentation.pinchZoomInThreshold) {
                if let result = performZoomAction?(.zoomIn) {
                    showIndicator(fontSize: result.effectiveFontSize, requestLayout: requestIndicatorLayout)
                }
                pinchReferenceScale = scale
            } else if relativeScale <= CGFloat(TerminalZoomPresentation.pinchZoomOutThreshold) {
                if let result = performZoomAction?(.zoomOut) {
                    showIndicator(fontSize: result.effectiveFontSize, requestLayout: requestIndicatorLayout)
                }
                pinchReferenceScale = scale
            }
        case .ended, .cancelled, .failed:
            isPinching = false
            pinchReferenceScale = 1
            scheduleIndicatorHide(after: TerminalZoomPresentation.indicatorGestureEndHideDelay)
        default:
            break
        }
    }

    private func showIndicator(fontSize: Double, requestLayout: RequestIndicatorLayout) {
        indicatorView.update(fontSize: fontSize)
        requestLayout()

        indicatorHideWorkItem?.cancel()
        indicatorView.isHidden = false
        UIView.animate(withDuration: TerminalZoomPresentation.indicatorFadeInDuration) { [indicatorView] in
            indicatorView.alpha = 1
        }
        scheduleIndicatorHide(after: TerminalZoomPresentation.indicatorHideDelay)
    }

    private func scheduleIndicatorHide(after delay: TimeInterval) {
        indicatorHideWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak indicatorView] in
            guard let indicatorView else { return }
            UIView.animate(withDuration: TerminalZoomPresentation.indicatorFadeOutDuration, animations: {
                indicatorView.alpha = 0
            }, completion: { _ in
                indicatorView.isHidden = true
            })
        }
        indicatorHideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }
}
#endif
