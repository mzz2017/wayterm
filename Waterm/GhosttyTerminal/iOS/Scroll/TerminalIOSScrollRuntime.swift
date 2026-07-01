#if os(iOS)
import UIKit

@MainActor
final class TerminalIOSScrollRuntime: NSObject {
    typealias MapLocation = @MainActor (CGPoint) -> CGPoint
    typealias HasSurface = @MainActor () -> Bool
    typealias SendMousePosition = @MainActor (CGPoint) -> Void
    typealias SendScrollEvent = @MainActor (Ghostty.Input.MouseScrollEvent) -> Void
    typealias RequestRender = @MainActor () -> Void

    private struct MomentumHandlers {
        let hasSurface: HasSurface
        let sendScrollEvent: SendScrollEvent
        let requestRender: RequestRender
    }

    private var isScrolling = false
    nonisolated private let momentumDisplayLinkOwner = TerminalIOSDisplayLinkOwner()
    private var momentumScrollState = TerminalMomentumScrollState()
    private var momentumHandlers: MomentumHandlers?

    deinit {
        momentumDisplayLinkOwner.invalidate()
    }

    func prepareForNativeHostScroll() {
        isScrolling = false
        stopMomentumScrolling()
    }

    func handlePanGesture(
        _ recognizer: UIPanGestureRecognizer,
        in view: UIView,
        mapLocation: MapLocation,
        hasSurface: @escaping HasSurface,
        sendMousePosition: @escaping SendMousePosition,
        sendScrollEvent: @escaping SendScrollEvent,
        requestRender: @escaping RequestRender
    ) {
        let translation = recognizer.translation(in: view)
        let location = recognizer.location(in: view)

        switch recognizer.state {
        case .began:
            isScrolling = true
            stopMomentumScrolling()
        case .changed:
            sendMousePosition(mapLocation(location))
            let scrollEvent = Ghostty.Input.MouseScrollEvent(
                x: Double(translation.x) * TerminalScrollGesturePresentation.scrollMultiplier,
                y: Double(translation.y) * TerminalScrollGesturePresentation.scrollMultiplier,
                mods: Ghostty.Input.ScrollMods(precision: true, momentum: .none)
            )
            sendScrollEvent(scrollEvent)
            requestRender()
            recognizer.setTranslation(.zero, in: view)
        case .ended:
            isScrolling = false
            startMomentumScrolling(
                velocity: recognizer.velocity(in: view),
                hasSurface: hasSurface,
                sendScrollEvent: sendScrollEvent,
                requestRender: requestRender
            )
        case .cancelled, .failed:
            isScrolling = false
            stopMomentumScrolling()
        default:
            break
        }
    }

    func stopMomentumScrolling() {
        momentumDisplayLinkOwner.invalidate()
        momentumScrollState.reset()
        momentumHandlers = nil
    }

    private func startMomentumScrolling(
        velocity: CGPoint,
        hasSurface: @escaping HasSurface,
        sendScrollEvent: @escaping SendScrollEvent,
        requestRender: @escaping RequestRender
    ) {
        guard momentumScrollState.start(gestureVelocity: velocity) else {
            sendMomentumEnd(sendScrollEvent: sendScrollEvent)
            return
        }

        momentumHandlers = MomentumHandlers(
            hasSurface: hasSurface,
            sendScrollEvent: sendScrollEvent,
            requestRender: requestRender
        )
        let displayLink = CADisplayLink(target: self, selector: #selector(momentumScrollTick))
        momentumDisplayLinkOwner.replace(with: displayLink)
        displayLink.add(to: .main, forMode: .common)
    }

    @objc private func momentumScrollTick() {
        guard let momentumHandlers else {
            stopMomentumScrolling()
            return
        }

        guard momentumHandlers.hasSurface() else {
            stopMomentumScrolling()
            return
        }

        guard let scrollEvent = momentumScrollState.nextFrameEvent() else {
            stopMomentumScrolling()
            sendMomentumEnd(sendScrollEvent: momentumHandlers.sendScrollEvent)
            return
        }

        momentumHandlers.sendScrollEvent(scrollEvent)
        momentumHandlers.requestRender()
    }

    private func sendMomentumEnd(sendScrollEvent: SendScrollEvent) {
        let endEvent = Ghostty.Input.MouseScrollEvent(
            x: 0,
            y: 0,
            mods: Ghostty.Input.ScrollMods(precision: true, momentum: .ended)
        )
        sendScrollEvent(endEvent)
        momentumScrollState.reset()
    }
}
#endif
