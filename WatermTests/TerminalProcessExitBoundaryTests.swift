import Foundation
import Testing

// Test Context:
// These source-boundary tests protect root and split terminal process-exit
// ownership. The invariant is that SwiftUI may receive terminal process-exit
// callbacks, but it must forward them as synchronous intent while
// TerminalSessions application managers own async request tracking, coalescing,
// and close cleanup. Update these tests only if process-exit orchestration
// intentionally moves to another non-UI owner.
@Suite(.serialized)
struct TerminalProcessExitBoundaryTests {
    @Test
    func rootTerminalContainerUsesSessionProcessExitRequestBoundary() throws {
        let root = try sourceRoot()
        let source = try source(
            at: root.appendingPathComponent("Waterm/Features/TerminalSessions/UI/Terminal/TerminalContainerView.swift")
        )

        // Given the root terminal process-exit path.
        #expect(
            source.contains("requestSessionProcessExit"),
            "Root terminal process exit should send intent to ConnectionSessionManager."
        )

        // Then SwiftUI must not bridge process exit with a direct dispatch to the low-level handler.
        #expect(!source.contains("ConnectionSessionManager.shared.handleShellExit"))
        #expect(!source.containsRegex(#"DispatchQueue\.main\.async\s*\{[^}]*handleShellExit"#))
    }

    @Test
    func rootTerminalWrapperDoesNotCallLowLevelSessionExitDirectly() throws {
        let root = try sourceRoot()
        let source = try source(
            at: root.appendingPathComponent("Waterm/Features/TerminalSessions/UI/Terminal/SSHTerminalWrapper.swift")
        )

        // Given the root terminal representable.
        #expect(source.contains("terminalView.onProcessExit = onProcessExit"))

        // Then the representable forwards the callback instead of owning session exit handling.
        #expect(!source.contains("handleShellExit(for:"))
        #expect(!source.contains("requestSessionProcessExit"))
        #expect(!source.containsRegex(#"Task\s*(?:\([^)]*\))?\s*\{[^}]*ProcessExit"#))
    }

    @Test
    func splitTerminalViewUsesPaneProcessExitRequestBoundary() throws {
        let root = try sourceRoot()
        let source = try source(
            at: root.appendingPathComponent("Waterm/Features/TerminalSessions/UI/Splits/TerminalView.swift")
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
            at: root.appendingPathComponent("Waterm/Features/TerminalSessions/UI/Splits/SSHTerminalPaneWrapper.swift")
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
        while url.lastPathComponent != "WatermTests" {
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
