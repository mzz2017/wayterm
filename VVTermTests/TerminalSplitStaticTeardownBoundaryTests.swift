import Foundation
import Testing

// Test Context:
// Protected behavior: split-pane representable static teardown delegates pane
// liveness, surface detach, and closed-pane surface cleanup to the injected
// TerminalSessions application owner available through the coordinator.
// Target invariant: static teardown may pause UI surfaces locally, but it must
// not resolve TerminalTabManager.shared; it must use coordinator.tabManager.
// Fake assumptions: this is a source-boundary test because constructing
// NSViewRepresentable teardown inputs would require platform UI surfaces and
// Ghostty.
// Update guidance: update this test only if split static teardown is redesigned
// to call a different injected application owner or moves out of representable
// static lifecycle methods entirely.
@Suite(.serialized)
struct TerminalSplitStaticTeardownBoundaryTests {
    @Test
    func splitStaticTeardownUsesCoordinatorManager() throws {
        let root = try sourceRoot()
        let source = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/UI/Splits/TerminalView.swift")
        )
        let teardown = try slice(
            startingAt: "static func dismantleNSView",
            endingBefore: "func makeCoordinator",
            in: source
        )

        // Given split static representable teardown receives a coordinator with the injected manager.
        for expectedCall in [
            "coordinator.tabManager.paneStates",
            "coordinator.tabManager.detachSurfaceForPaneViewDisappeared",
            "coordinator.tabManager.detachSurfaceForClosedPane"
        ] {
            #expect(
                teardown.contains(expectedCall),
                "Split static teardown should use injected manager call \(expectedCall)."
            )
        }

        // Then teardown must not bypass the coordinator dependency through the singleton.
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
