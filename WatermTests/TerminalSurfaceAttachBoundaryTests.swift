import Foundation
import Testing

// Test Context:
// These source-boundary tests protect terminal surface attach ownership. The
// invariant is that SwiftUI/AppKit/UIKit representables report surface
// readiness and value context, while TerminalSessions application managers own
// shell-state checks, reconnect-reset consumption, and runtime-start attach
// tasks. Update these tests only if that orchestration intentionally moves to
// another non-UI owner.
@Suite(.serialized)
struct TerminalSurfaceAttachBoundaryTests {
    @Test
    func rootTerminalWrapperUsesSurfaceAttachRequestBoundary() throws {
        let root = try sourceRoot()
        let source = try source(
            at: root.appendingPathComponent("Waterm/Features/TerminalSessions/UI/Terminal/SSHTerminalWrapper.swift")
        )

        // Given the root session terminal representable.
        #expect(
            source.contains("requestSurfaceAttach"),
            "Root terminal wrapper should send surface attach intent to ConnectionSessionManager."
        )

        // Then the representable must not own shell-state or reconnect-reset
        // policy for deciding whether to start/attach runtime work.
        #expect(!source.contains("shellId(for:"))
        #expect(!source.contains("isShellStartInFlight"))
        #expect(!source.contains("consumeTerminalReconnectReset"))
        #expect(!source.contains("isSuspendingForBackground"))
        #expect(!source.containsRegex(#"Task\s*\{[^\n]*await\s+ConnectionSessionManager\.shared\.attachSurface"#))
    }

    @Test
    func splitTerminalWrapperUsesSurfaceAttachRequestBoundary() throws {
        let root = try sourceRoot()
        let source = try source(
            at: root.appendingPathComponent("Waterm/Features/TerminalSessions/UI/Splits/SSHTerminalPaneWrapper.swift")
        )
        let wrapper = try slice(
            startingAt: "struct SSHTerminalPaneWrapper",
            endingBefore: "#endif",
            in: source
        )

        // Given the split pane terminal representable.
        #expect(
            wrapper.contains("requestSurfaceAttach"),
            "Split terminal wrapper should send surface attach intent to TerminalTabManager."
        )

        // Then split UI must not launch the runtime attach task directly or
        // preflight shell-state ownership before asking the manager.
        #expect(!wrapper.contains("shellId(for:"))
        #expect(!wrapper.contains("isShellStartInFlight"))
        #expect(!wrapper.containsRegex(#"Task\s*\{[^\n]*await\s+TerminalTabManager\.shared\.attachSurface"#))
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
