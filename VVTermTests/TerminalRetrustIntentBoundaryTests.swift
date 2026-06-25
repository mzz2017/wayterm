import Foundation
import Testing

// Test Context:
// These source-boundary tests protect terminal host-retrust intent ownership.
// The production contract is that SwiftUI terminal views may present the
// confirmation alert and send synchronous retrust intent, while TerminalSessions
// Application managers own known-host mutation, reconnect, request coalescing,
// and awaitable lifecycle state. Update these tests only when host-retrust
// lifecycle ownership intentionally moves to another non-UI application owner.

@Suite(.serialized)
struct TerminalRetrustIntentBoundaryTests {
    @Test
    func terminalContainerRetrustSendsIntentWithoutOwningRetrustTask() throws {
        let root = try sourceRoot()
        let source = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/UI/Terminal/TerminalContainerView.swift")
        )
        let retrustSlice = try slice(
            startingAt: "private func retrustHostAndRetry()",
            endingBefore: "private func attemptAutoReconnectIfNeeded()",
            in: source
        )

        // Given the single-session terminal host-retrust SwiftUI helper.
        #expect(
            retrustSlice.contains("ConnectionSessionManager.shared.requestSessionHostRetrust"),
            "The retrust helper should send request intent to the session manager."
        )

        // Then SwiftUI must not own trusted-host mutation or reconnect work.
        #expect(!retrustSlice.containsRegex(#"Task\s*\{"#))
        #expect(!retrustSlice.containsRegex(#"await\s+ConnectionSessionManager\.shared\.retrustHostAndReconnect\s*\("#))
        #expect(!retrustSlice.containsRegex(#"ConnectionSessionManager\.shared\.retrustHostAndReconnect\s*\("#))
    }

    @Test
    func splitTerminalRetrustSendsIntentWithoutOwningRetrustTask() throws {
        let root = try sourceRoot()
        let source = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/UI/Splits/TerminalView.swift")
        )
        let retrustSlice = try slice(
            startingAt: "private func retrustHostAndRetry()",
            endingBefore: "private func attemptAutoReconnectIfNeeded()",
            in: source
        )

        // Given the split terminal host-retrust SwiftUI helper.
        #expect(
            retrustSlice.contains("tabManager.requestPaneHostRetrust"),
            "The retrust helper should send request intent to the injected tab manager."
        )

        // Then SwiftUI must not own trusted-host mutation or reconnect work.
        #expect(!retrustSlice.containsRegex(#"Task\s*\{"#))
        #expect(!retrustSlice.containsRegex(#"await\s+TerminalTabManager\.shared\.retrustHostAndReconnect\s*\("#))
        #expect(!retrustSlice.containsRegex(#"TerminalTabManager\.shared\.retrustHostAndReconnect\s*\("#))
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
        while url.pathComponents.count > 1 {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("VVTerm.xcodeproj").path) {
                return url
            }
            url.deleteLastPathComponent()
        }
        throw SourceRootError.notFound
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
