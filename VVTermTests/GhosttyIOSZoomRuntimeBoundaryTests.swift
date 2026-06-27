import Foundation
import Testing

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
            at: root.appendingPathComponent("VVTerm/GhosttyTerminal/GhosttyTerminalView+iOS.swift")
        )
        let runtimeSource = try source(
            at: root.appendingPathComponent("VVTerm/GhosttyTerminal/TerminalIOSZoomRuntime.swift")
        )

        // Then the view delegates pinch state and indicator presentation to the runtime.
        #expect(viewSource.contains("private let zoomRuntime = TerminalIOSZoomRuntime()"))
        #expect(viewSource.contains("zoomRuntime.installIndicator"))
        #expect(viewSource.contains("zoomRuntime.handlePinchGesture"))
        #expect(viewSource.contains("zoomRuntime.isPinching"))
        #expect(viewSource.contains("zoomRuntime.bringIndicatorToFront"))

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
