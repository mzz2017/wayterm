import Foundation
import Testing

// Test Context:
// These source-boundary tests protect terminal resize ownership. The invariant
// is that SwiftUI/AppKit/UIKit resize callbacks forward dimensions as intent,
// while TerminalSessions application managers own async resize request tracking,
// coalescing, and close cleanup. Update these tests only if that orchestration
// intentionally moves to another non-UI owner.
@Suite(.serialized)
struct TerminalResizeBoundaryTests {
    @Test
    func rootTerminalWrapperUsesResizeRequestBoundary() throws {
        let root = try sourceRoot()
        let source = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/UI/Terminal/SSHTerminalWrapper.swift")
        )

        // Given the root session terminal representable.
        #expect(
            source.contains("requestSessionResize"),
            "Root terminal wrapper should send resize intent to ConnectionSessionManager."
        )

        // Then the representable must not own an async resizeSession task.
        #expect(!source.contains("ConnectionSessionManager.shared.resizeSession"))
        #expect(!source.containsRegex(#"Task\s*(?:\([^)]*\))?\s*\{[^}]*resizeSession"#))
    }

    @Test
    func splitTerminalWrapperUsesResizeRequestBoundary() throws {
        let root = try sourceRoot()
        let source = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/UI/Splits/SSHTerminalPaneWrapper.swift")
        )
        let wrapper = try slice(
            startingAt: "struct SSHTerminalPaneWrapper",
            endingBefore: "#endif",
            in: source
        )

        // Given the split pane terminal representable.
        #expect(
            wrapper.contains("requestPaneResize"),
            "Split terminal wrapper should send resize intent to TerminalTabManager."
        )

        // Then the representable must not own an async resizePane task.
        #expect(!wrapper.contains("TerminalTabManager.shared.resizePane"))
        #expect(!wrapper.containsRegex(#"Task\s*(?:\([^)]*\))?\s*\{[^}]*resizePane"#))
    }

    @Test
    func iOSActiveConnectionRedrawUsesResizeRequestBoundary() throws {
        let root = try sourceRoot()
        let source = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/UI/iOS/iOSTerminalView.swift")
        )
        let redraw = try slice(
            startingAt: "private func refreshTerminal",
            endingBefore: "private func focusTerminal",
            in: source
        )

        // Given the iOS active-connection redraw path.
        #expect(
            redraw.contains("requestSessionResize"),
            "iOS redraw should send resize intent to ConnectionSessionManager."
        )

        // Then redraw must not own an async resizeSession task.
        #expect(!redraw.contains("ConnectionSessionManager.shared.resizeSession"))
        #expect(!redraw.containsRegex(#"Task\s*(?:\([^)]*\))?\s*\{[^}]*resizeSession"#))
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
