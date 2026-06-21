import Foundation
import Testing

// Test Context:
// These source-boundary tests protect split-pane process-exit ownership. The
// invariant is that SwiftUI may receive terminal process-exit callbacks, but it
// must forward them as synchronous intent while TerminalTabManager owns async
// request tracking, coalescing, and close cleanup. Update these tests only if
// pane process-exit orchestration intentionally moves to another non-UI owner.
@Suite(.serialized)
struct TerminalProcessExitBoundaryTests {
    @Test
    func splitTerminalViewUsesPaneProcessExitRequestBoundary() throws {
        let root = try sourceRoot()
        let source = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/UI/Splits/TerminalView.swift")
        )

        // Given the split terminal view process-exit path.
        #expect(
            source.contains("requestPaneProcessExit"),
            "Split terminal process exit should send intent to TerminalTabManager."
        )

        // Then SwiftUI must not own an async handlePaneExit task.
        #expect(!source.contains("await tabManager.handlePaneExit"))
        #expect(!source.containsRegex(#"Task\s*(?:\([^)]*\))?\s*\{[^}]*handlePaneExit"#))
    }

    @Test
    func splitTerminalPaneWrapperDoesNotCallLowLevelPaneExitDirectly() throws {
        let root = try sourceRoot()
        let source = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/UI/Splits/TerminalView.swift")
        )
        let wrapper = try slice(
            startingAt: "struct SSHTerminalPaneWrapper",
            endingBefore: "#endif",
            in: source
        )

        // Given the split terminal representable.
        #expect(wrapper.contains("terminalView.onProcessExit = onProcessExit"))

        // Then the representable forwards the callback instead of owning pane exit handling.
        #expect(!wrapper.contains("handlePaneExit(for:"))
        #expect(!wrapper.contains("requestPaneProcessExit"))
        #expect(!wrapper.containsRegex(#"Task\s*(?:\([^)]*\))?\s*\{[^}]*ProcessExit"#))
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

private extension String {
    func containsRegex(_ pattern: String) -> Bool {
        range(of: pattern, options: .regularExpression) != nil
    }
}
