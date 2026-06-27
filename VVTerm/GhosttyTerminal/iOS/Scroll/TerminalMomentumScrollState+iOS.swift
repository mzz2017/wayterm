//
//  TerminalMomentumScrollState+iOS.swift
//  VVTerm
//
//  Pure inertial scroll state for iOS Ghostty terminal gestures.
//

#if os(iOS)
import CoreGraphics

enum TerminalScrollGesturePresentation {
    static let scrollMultiplier: Double = 1.5
}

struct TerminalMomentumScrollState {
    private static let deceleration: Double = 0.92
    private static let minimumVelocity: Double = 50.0
    private static let minimumFrameVelocity: CGFloat = 0.5

    private var velocity: CGPoint = .zero
    private var phase: Ghostty.Input.Momentum = .none

    var isActive: Bool {
        phase != .none
    }

    mutating func start(gestureVelocity: CGPoint) -> Bool {
        guard abs(gestureVelocity.y) > Self.minimumVelocity || abs(gestureVelocity.x) > Self.minimumVelocity else {
            reset()
            return false
        }

        velocity = CGPoint(
            x: gestureVelocity.x / 60.0 * TerminalScrollGesturePresentation.scrollMultiplier * 0.5,
            y: gestureVelocity.y / 60.0 * TerminalScrollGesturePresentation.scrollMultiplier * 0.5
        )
        phase = .began
        return true
    }

    mutating func nextFrameEvent() -> Ghostty.Input.MouseScrollEvent? {
        guard isActive else { return nil }

        velocity.x *= Self.deceleration
        velocity.y *= Self.deceleration

        guard abs(velocity.x) >= Self.minimumFrameVelocity || abs(velocity.y) >= Self.minimumFrameVelocity else {
            reset()
            return nil
        }

        let event = Ghostty.Input.MouseScrollEvent(
            x: Double(velocity.x),
            y: Double(velocity.y),
            mods: Ghostty.Input.ScrollMods(
                precision: true,
                momentum: phase == .began ? .began : .changed
            )
        )
        phase = .changed
        return event
    }

    mutating func reset() {
        velocity = .zero
        phase = .none
    }
}

#endif
