import Foundation
import Testing

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
            at: root.appendingPathComponent("VVTerm/GhosttyTerminal/GhosttyTerminalView+iOS.swift")
        )
        let runtimeSource = try source(
            at: root.appendingPathComponent("VVTerm/GhosttyTerminal/TerminalIOSScrollRuntime.swift")
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
