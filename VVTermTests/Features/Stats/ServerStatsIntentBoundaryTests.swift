import Foundation
import Testing

// Test Context:
// These tests protect Stats visibility/retry lifecycle ownership. SwiftUI may
// render cards, show errors, and send visible/hidden/retry/disappear intent,
// but ServerStatsCollector must own the async collection start/stop request
// tasks, cancellation ordering, and pending request visibility. The tests
// inspect source placement only; update them only if Stats request ownership
// intentionally moves to another non-UI application owner with equivalent
// awaitable close/retry ordering.
@Suite
struct ServerStatsIntentBoundaryTests {
    @Test
    func serverStatsViewSendsCollectionIntentInsteadOfOwningTasks() throws {
        // Given the Stats SwiftUI source.
        let root = try sourceRoot()
        let source = try source(
            at: root.appendingPathComponent("VVTerm/Features/Stats/UI/ServerStatsView.swift")
        )

        // Then visible, hidden, retry, and disappearance flows must send intent
        // to ServerStatsCollector request APIs instead of awaiting low-level
        // collection helpers from SwiftUI lifecycle callbacks.
        #expect(
            source.contains("requestStartCollecting(for: server, using: borrowedLeaseProvider())"),
            "Stats visible/retry intent should route through ServerStatsCollector.requestStartCollecting."
        )
        #expect(
            source.contains("requestStopCollecting()"),
            "Stats hidden/disappear intent should route through ServerStatsCollector.requestStopCollecting."
        )
        #expect(
            !containsRegex(#"Task\s*\{\s*await\s+statsCollector\.startCollecting"#, in: source),
            "ServerStatsView Retry must not own an async start task."
        )
        #expect(
            !containsRegex(#"\.task\s*\(\s*id:\s*makeTaskKey\(\)\s*\)\s*\{[\s\S]*await\s+statsCollector\.(startCollecting|stopCollectingAndWait)"#, in: source),
            "ServerStatsView visibility lifecycle must not directly await Stats start/stop helpers."
        )
        #expect(
            !containsRegex(#"await\s+statsCollector\.(startCollecting|stopCollectingAndWait)"#, in: source),
            "ServerStatsView should not directly await low-level Stats collection lifecycle helpers."
        )
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

    private func containsRegex(_ pattern: String, in source: String) -> Bool {
        source.range(of: pattern, options: .regularExpression) != nil
    }

    private enum SourceRootError: Error {
        case notFound
    }
}
