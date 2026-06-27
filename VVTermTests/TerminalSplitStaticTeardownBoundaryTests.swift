import Foundation
import Testing

// Test Context:
// Protected behavior: split-pane representable static teardown reports
// disappeared terminal surfaces to the injected TerminalSessions application
// owner available through the coordinator.
// Target invariant: static teardown must not inspect pane collections or decide
// whether a surface should be detached or cleaned up.
// Fake assumptions: this is a source-boundary test because constructing
// NSViewRepresentable teardown inputs would require platform UI surfaces and
// Ghostty.
// Update guidance: update this test only if disappeared-surface policy moves to
// another non-UI owner or split static teardown goes away entirely.
@Suite(.serialized)
struct TerminalSplitStaticTeardownBoundaryTests {
    @Test
    func splitStaticTeardownUsesCoordinatorManager() throws {
        let root = try sourceRoot()
        let source = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/UI/Splits/SSHTerminalPaneWrapper.swift")
        )
        let teardown = try slice(
            startingAt: "static func dismantleNSView",
            endingBefore: "func makeCoordinator",
            in: source
        )

        // Given split static representable teardown receives a coordinator with the injected manager.
        #expect(
            teardown.contains("coordinator.tabManager.handlePaneSurfaceViewDisappeared"),
            "Split static teardown should send one disappeared-surface intent to the application manager."
        )

        // Then teardown must not read application state or select detach/cleanup branches itself.
        #expect(!teardown.contains("coordinator.tabManager.paneStates"))
        #expect(!teardown.contains("coordinator.tabManager.detachSurfaceForPaneViewDisappeared"))
        #expect(!teardown.contains("coordinator.tabManager.detachSurfaceForClosedPane"))
        #expect(!teardown.contains("pauseRendering()"))
        #expect(!teardown.contains("TerminalTabManager.shared"))
    }

    private func slice(startingAt marker: String, endingBefore endMarker: String, in source: String) throws -> String {
        guard let start = source.range(of: marker),
              let end = source.range(of: endMarker, range: start.lowerBound..<source.endIndex)
        else {
            throw SourceSliceError.notFound
        }
        return String(source[start.lowerBound..<end.lowerBound])
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

    private enum SourceSliceError: Error {
        case notFound
    }
}
