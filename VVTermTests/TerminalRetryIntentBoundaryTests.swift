import Foundation
import Testing

// Test Context:
// These source-boundary tests protect terminal retry intent ownership. The
// production contract is that SwiftUI terminal views may update presentation
// state and send synchronous retry intent, while TerminalSessions Application
// managers own credential loading, reconnect gating, and retry task lifecycles.
// Update these tests only when retry lifecycle ownership intentionally moves to
// another non-UI application owner; do not update them for cosmetic UI rewrites.

@Suite(.serialized)
struct TerminalRetryIntentBoundaryTests {
    @Test
    func terminalContainerRetrySendsIntentWithoutOwningRetryTasks() throws {
        let root = try sourceRoot()
        let source = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/UI/Terminal/TerminalContainerView.swift")
        )
        let retrySlice = try slice(
            startingAt: "private func retryConnection()",
            endingBefore: "private func requestMoshInstallAndReconnect()",
            in: source
        )
        // Given the single-session terminal SwiftUI retry source.
        #expect(
            retrySlice.contains("ConnectionSessionManager.shared.requestSessionRetry"),
            "The retry helper should send request intent to the session manager."
        )

        // Then SwiftUI must not own retry tasks or call the old async retry
        // helper directly.
        #expect(!source.containsRegex(#"(?s)Task\s*\{[^}]*retryConnection\s*\("#))
        #expect(!source.containsRegex(#"await\s+retryConnection\s*\("#))
        #expect(!source.containsRegex(#"ConnectionSessionManager\.shared\.retrySessionConnection\s*\("#))
        #expect(!retrySlice.contains("async"))
    }

    @Test
    func splitTerminalRetrySendsIntentWithoutOwningRetryTasks() throws {
        let root = try sourceRoot()
        let source = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/UI/Splits/TerminalView.swift")
        )
        let retrySlice = try slice(
            startingAt: "private func retryConnection()",
            endingBefore: "private func startConnectWatchdog()",
            in: source
        )
        // Given the split terminal SwiftUI retry source.
        #expect(
            retrySlice.contains("TerminalTabManager.shared.requestPaneRetry"),
            "The retry helper should send request intent to the tab manager."
        )

        // Then SwiftUI must not own retry tasks or call the old async retry
        // helper directly.
        #expect(!source.containsRegex(#"(?s)Task\s*\{[^}]*retryConnection\s*\("#))
        #expect(!source.containsRegex(#"await\s+retryConnection\s*\("#))
        #expect(!source.containsRegex(#"TerminalTabManager\.shared\.retryPaneConnection\s*\("#))
        #expect(!retrySlice.containsRegex(#"Task\s*\{"#))
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
