#if os(iOS)
import CoreGraphics
import Testing
@testable import Waterm

// Test Context:
// These tests protect iOS terminal inertial scroll state. The fake input is pure
// gesture velocity; no CADisplayLink, simulator hardware, or Ghostty surface is
// involved. Update only when Waterm intentionally changes momentum thresholds,
// scaling, or Ghostty momentum phase ordering.

struct TerminalMomentumScrollStateTests {
    @Test
    func insignificantVelocityDoesNotStartMomentum() {
        var state = TerminalMomentumScrollState()

        // Given a gesture velocity below the terminal momentum threshold.
        let didStart = state.start(gestureVelocity: CGPoint(x: 0, y: 40))

        // Then no display-link momentum should be scheduled.
        #expect(!didStart, "Low velocity should fall through to a single momentum end event.")
        #expect(!state.isActive)
    }

    @Test
    func firstFrameUsesBeganMomentumPhaseThenChanged() throws {
        var state = TerminalMomentumScrollState()

        // Given a vertical pan velocity high enough to start inertial scrolling.
        let didStart = state.start(gestureVelocity: CGPoint(x: 0, y: 120))
        #expect(didStart)

        // When two animation frames are consumed.
        let firstFrame = state.nextFrameEvent()
        let secondFrame = state.nextFrameEvent()
        let first = try #require(firstFrame)
        let second = try #require(secondFrame)

        // Then the first Ghostty event is marked as began and later frames are changed.
        #expect(first.mods.precision)
        #expect(first.mods.momentum == .began)
        #expect(abs(first.y - 1.38) < 0.0001, "Velocity should match the existing scale and deceleration.")
        #expect(second.mods.momentum == .changed)
        #expect(abs(second.y - 1.2696) < 0.0001, "Subsequent frames should keep applying deceleration.")
    }

    @Test
    func resetClearsActiveMomentum() {
        var state = TerminalMomentumScrollState()
        let didStart = state.start(gestureVelocity: CGPoint(x: 100, y: 0))
        #expect(didStart)

        // When the view stops momentum because a gesture, host scroll, or teardown wins.
        state.reset()

        // Then the pure momentum state is back to idle.
        let nextFrame = state.nextFrameEvent()
        #expect(!state.isActive)
        #expect(nextFrame == nil)
    }
}
#endif
