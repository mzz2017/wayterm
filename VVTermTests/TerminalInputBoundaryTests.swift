import Foundation
import Testing

// Test Context:
// These source-boundary tests protect terminal keyboard input ownership. The
// invariant is that SwiftUI/AppKit/UIKit representables forward write callback
// bytes as intent, while TerminalSessions application managers own async input
// request tracking and ordering. Update these tests only if that orchestration
// intentionally moves to another non-UI owner.
@Suite(.serialized)
struct TerminalInputBoundaryTests {
    @Test
    func rootTerminalWrapperUsesInputRequestBoundary() throws {
        let root = try sourceRoot()
        let source = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/UI/Terminal/SSHTerminalWrapper.swift")
        )

        // Given the root session terminal representable.
        #expect(
            source.contains("requestSessionInput"),
            "Root terminal wrapper should send input intent to ConnectionSessionManager."
        )

        // Then the representable must not own an async sendInput task.
        #expect(!source.contains("ConnectionSessionManager.shared.sendInput"))
        #expect(!source.containsRegex(#"Task\s*(?:\([^)]*\))?\s*\{[^\n]*sendInput"#))
    }

    @Test
    func splitTerminalWrapperUsesInputRequestBoundary() throws {
        let root = try sourceRoot()
        let source = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/UI/Splits/TerminalView.swift")
        )
        let wrapper = try slice(
            startingAt: "struct SSHTerminalPaneWrapper",
            endingBefore: "#endif",
            in: source
        )

        // Given the split pane terminal representable.
        #expect(
            wrapper.contains("requestPaneInput"),
            "Split terminal wrapper should send input intent to TerminalTabManager."
        )

        // Then the representable must not own an async sendInput task.
        #expect(!wrapper.contains("TerminalTabManager.shared.sendInput"))
        #expect(!wrapper.containsRegex(#"Task\s*(?:\([^)]*\))?\s*\{[^\n]*sendInput"#))
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
