import Foundation
import Testing

#if os(iOS)
import UIKit
@testable import VVTerm
#endif

// Test Context:
// Protects ownership of iOS pinch-zoom presentation. GhosttyTerminalView should
// forward pinch intent, while TerminalIOSZoomRuntime owns pinching state, scale
// reference, zoom indicator view, and delayed hide work item.
// Update this test only when zoom presentation ownership intentionally moves.
@Suite(.serialized)
struct GhosttyIOSZoomRuntimeBoundaryTests {
    @Test
    func iOSTerminalViewDelegatesPinchZoomPresentationToRuntimeOwner() throws {
        // Given the terminal view and the dedicated zoom runtime source.
        let root = try sourceRoot()
        let viewSource = try source(
            at: root.appendingPathComponent("VVTerm/GhosttyTerminal/iOS/View/GhosttyTerminalView+iOS.swift")
        )
        let zoomGestureSource = try source(
            at: root.appendingPathComponent("VVTerm/GhosttyTerminal/iOS/Zoom/GhosttyTerminalView+ZoomGesture+iOS.swift")
        )
        let runtimeSource = try source(
            at: root.appendingPathComponent("VVTerm/GhosttyTerminal/iOS/Zoom/TerminalIOSZoomRuntime.swift")
        )

        // Then the view delegates pinch state and indicator presentation to the runtime.
        #expect(viewSource.contains("let zoomRuntime = TerminalIOSZoomRuntime()"))
        #expect(viewSource.contains("zoomRuntime.installIndicator"))
        #expect(!viewSource.contains("func handlePinchGesture"))
        #expect(!viewSource.contains("var canHandlePinchZoom"))
        #expect(zoomGestureSource.contains("zoomRuntime.handlePinchGesture"))
        #expect(zoomGestureSource.contains("zoomRuntime.bringIndicatorToFront"))
        #expect(zoomGestureSource.contains("var canHandlePinchZoom"))

        // And the view no longer owns the pinch zoom state machine or indicator lifecycle.
        #expect(!viewSource.contains("private var isPinchingTerminalZoom"))
        #expect(!viewSource.contains("private var pinchReferenceScale"))
        #expect(!viewSource.contains("private let zoomIndicatorView"))
        #expect(!viewSource.contains("private var zoomIndicatorHideWorkItem"))
        #expect(!viewSource.contains("private func showZoomIndicator"))
        #expect(!viewSource.contains("private func scheduleZoomIndicatorHide"))
        #expect(!viewSource.contains("private func updateZoomIndicatorLayout"))

        // And the runtime remains the stable owner of that extracted state.
        #expect(runtimeSource.contains("final class TerminalIOSZoomRuntime"))
        #expect(runtimeSource.contains("private var isPinching"))
        #expect(runtimeSource.contains("private var pinchReferenceScale"))
        #expect(runtimeSource.contains("private let indicatorView"))
        #expect(runtimeSource.contains("private var indicatorHideWorkItem"))
        #expect(runtimeSource.contains("func handlePinchGesture"))
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
// These behavior tests protect iOS pinch-zoom routing after it was extracted out
// of GhosttyTerminalView. The runtime owns pinch state, thresholding, momentum
// cancellation, and indicator layout requests; update these only when that user
// interaction intentionally changes.
@Suite(.serialized)
@MainActor
struct GhosttyIOSZoomRuntimeBehaviorTests {
    @Test
    func pinchZoomBeginsStopsMomentumAndRoutesThresholdCrossings() {
        let runtime = TerminalIOSZoomRuntime()
        var events: [String] = []
        let performZoomAction: TerminalIOSZoomRuntime.PerformZoomAction = { action in
            events.append("zoom-\(action)")
            let fontSize = action == .zoomIn ? 13.0 : 11.0
            return TerminalZoomResult(
                presentationOverrides: TerminalPresentationOverrides(fontSize: fontSize),
                effectiveFontSize: fontSize
            )
        }

        // Given a pinch begins on an iOS terminal that supports pinch zoom.
        runtime.handlePinchGestureState(
            .began,
            scale: 1,
            canHandlePinchZoom: true,
            currentFontSize: { 12 },
            performZoomAction: performZoomAction,
            stopMomentumScrolling: { events.append("stop-momentum") },
            requestIndicatorLayout: { events.append("layout") }
        )

        // Then pinch state starts, momentum scrolling stops, and the indicator is laid out.
        #expect(runtime.isPinchingTerminalZoom, "A began pinch should enter terminal zoom state.")
        #expect(events == ["stop-momentum", "layout"])

        // When the pinch crosses zoom-in and zoom-out thresholds.
        runtime.handlePinchGestureState(
            .changed,
            scale: CGFloat(TerminalZoomPresentation.pinchZoomInThreshold),
            canHandlePinchZoom: true,
            currentFontSize: { 12 },
            performZoomAction: performZoomAction,
            stopMomentumScrolling: { events.append("stop-momentum") },
            requestIndicatorLayout: { events.append("layout") }
        )

        runtime.handlePinchGestureState(
            .changed,
            scale: CGFloat(TerminalZoomPresentation.pinchZoomInThreshold * TerminalZoomPresentation.pinchZoomOutThreshold),
            canHandlePinchZoom: true,
            currentFontSize: { 12 },
            performZoomAction: performZoomAction,
            stopMomentumScrolling: { events.append("stop-momentum") },
            requestIndicatorLayout: { events.append("layout") }
        )

        // Then each crossing is routed to one zoom action and indicator refresh.
        #expect(events == [
            "stop-momentum",
            "layout",
            "zoom-zoomIn",
            "layout",
            "zoom-zoomOut",
            "layout"
        ])

        // When the gesture ends, the runtime leaves pinch mode.
        runtime.handlePinchGestureState(
            .ended,
            scale: 1,
            canHandlePinchZoom: true,
            currentFontSize: { 12 },
            performZoomAction: performZoomAction,
            stopMomentumScrolling: { events.append("stop-momentum") },
            requestIndicatorLayout: { events.append("layout") }
        )

        #expect(!runtime.isPinchingTerminalZoom, "An ended pinch should leave terminal zoom state.")
    }

    @Test
    func pinchZoomDisabledClearsPinchingWithoutRoutingActions() {
        let runtime = TerminalIOSZoomRuntime()
        var events: [String] = []
        let performZoomAction: TerminalIOSZoomRuntime.PerformZoomAction = { action in
            events.append("zoom-\(action)")
            return nil
        }

        // Given pinch zoom is unavailable for the current terminal surface.
        runtime.handlePinchGestureState(
            .began,
            scale: 1,
            canHandlePinchZoom: false,
            currentFontSize: { 12 },
            performZoomAction: performZoomAction,
            stopMomentumScrolling: { events.append("stop-momentum") },
            requestIndicatorLayout: { events.append("layout") }
        )

        // Then the runtime consumes no zoom side effects and leaves pinch state clear.
        #expect(!runtime.isPinchingTerminalZoom, "Disabled pinch zoom should not enter terminal zoom state.")
        #expect(events.isEmpty, "Disabled pinch zoom should not route zoom or indicator side effects.")
    }
}
#endif
