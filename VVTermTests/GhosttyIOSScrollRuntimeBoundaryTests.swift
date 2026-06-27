import Foundation
import Testing

#if os(iOS)
import CoreGraphics
@testable import VVTerm
#endif

// Test Context:
// Protects ownership of iOS terminal scroll gesture runtime state.
// GhosttyTerminalView may route gesture intent, but TerminalIOSScrollRuntime
// owns pan scrolling state, CADisplayLink momentum, and momentum end emission.
// Update this test only when scroll runtime ownership intentionally moves.
@Suite(.serialized)
struct GhosttyIOSScrollRuntimeBoundaryTests {
    @Test
    func iOSTerminalViewDelegatesPanAndMomentumScrollingToRuntimeOwner() throws {
        // Given the terminal view and dedicated scroll runtime source.
        let root = try sourceRoot()
        let viewSource = try source(
            at: root.appendingPathComponent("VVTerm/GhosttyTerminal/iOS/View/GhosttyTerminalView+iOS.swift")
        )
        let runtimeSource = try source(
            at: root.appendingPathComponent("VVTerm/GhosttyTerminal/iOS/Scroll/TerminalIOSScrollRuntime.swift")
        )

        // Then the view delegates pan handling and stop intent to the runtime.
        #expect(viewSource.contains("private let scrollRuntime = TerminalIOSScrollRuntime()"))
        #expect(viewSource.contains("scrollRuntime.handlePanGesture"))
        #expect(viewSource.contains("scrollRuntime.stopMomentumScrolling"))

        // And the view no longer owns display-link momentum or the scroll state machine.
        #expect(!viewSource.contains("private var isScrolling"))
        #expect(!viewSource.contains("private var momentumDisplayLink"))
        #expect(!viewSource.contains("private var momentumScrollState"))
        #expect(!viewSource.contains("private func startMomentumScrolling"))
        #expect(!viewSource.contains("@objc private func momentumScrollTick"))
        #expect(!viewSource.contains("private func sendMomentumEnd"))

        // And the runtime remains the stable owner of extracted scroll state.
        #expect(runtimeSource.contains("final class TerminalIOSScrollRuntime"))
        #expect(runtimeSource.contains("private var isScrolling"))
        #expect(runtimeSource.contains("private var momentumDisplayLink"))
        #expect(runtimeSource.contains("private var momentumScrollState"))
        #expect(runtimeSource.contains("func handlePanGesture"))
        #expect(runtimeSource.contains("func stopMomentumScrolling"))
        #expect(runtimeSource.contains("@objc private func momentumScrollTick"))
    }

    private func source(at url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    private func sourceRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.lastPathComponent != "VVTermTests" {
            let next = url.deletingLastPathComponent()
            if next.path == url.path {
                throw SourceRootError.notFound
            }
            url = next
        }
        return url.deletingLastPathComponent()
    }

    private enum SourceRootError: Error {
        case notFound
    }
}

#if os(iOS)
// Test Context:
// These behavior tests protect the extracted scroll momentum policy. The runtime
// owns deceleration phases and reset behavior; update these only when the
// terminal's iOS momentum scrolling semantics intentionally change.
@Suite(.serialized)
@MainActor
struct GhosttyIOSScrollRuntimeBehaviorTests {
    @Test
    func momentumStateRejectsSmallVelocityAndStaysInactive() {
        var state = TerminalMomentumScrollState()

        // Given a pan velocity below the momentum threshold.
        let didStart = state.start(gestureVelocity: CGPoint(x: 0, y: 49))

        // Then no momentum sequence is started or emitted.
        #expect(!didStart, "Tiny flicks should not start terminal momentum scrolling.")
        #expect(!state.isActive, "Momentum state should remain inactive after a rejected start.")
        #expect(state.nextFrameEvent() == nil, "Inactive momentum state must not emit scroll frames.")
    }

    @Test
    func momentumStateEmitsBeganThenChangedFramesBeforeReset() throws {
        var state = TerminalMomentumScrollState()

        // Given a pan velocity high enough to start momentum scrolling.
        let didStart = state.start(gestureVelocity: CGPoint(x: 0, y: 120))

        // Then the first emitted frame starts a precision momentum sequence.
        #expect(didStart, "A real flick should start terminal momentum scrolling.")
        let firstFrameCandidate = state.nextFrameEvent()
        let firstFrame = try #require(firstFrameCandidate)
        #expect(firstFrame.mods.precision, "Momentum scroll frames should preserve precision scrolling.")
        #expect(firstFrame.mods.momentum == .began, "The first momentum frame should be marked as began.")
        #expect(firstFrame.y > 0, "Positive pan velocity should produce positive terminal scroll delta.")

        // And subsequent frames continue with decayed velocity until reset.
        let secondFrameCandidate = state.nextFrameEvent()
        let secondFrame = try #require(secondFrameCandidate)
        #expect(secondFrame.mods.momentum == .changed, "Follow-up momentum frames should be marked as changed.")
        #expect(abs(secondFrame.y) < abs(firstFrame.y), "Momentum velocity should decay between frames.")

        state.reset()
        #expect(!state.isActive, "Reset should clear active momentum state.")
        #expect(state.nextFrameEvent() == nil, "Reset momentum state must not emit stale frames.")
    }
}
#endif
