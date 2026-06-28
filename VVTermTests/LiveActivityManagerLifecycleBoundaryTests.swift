import Foundation
import Testing

// Test Context:
// Live Activity refresh requests cross ActivityKit async boundaries, so an
// older refresh must not clear or overwrite state after a newer refresh starts.
// This boundary test protects the request-ID gate used around the ActivityKit
// calls; update it when LiveActivityManager gains injectable ActivityKit fakes
// and this can move to a direct ordering test.

struct LiveActivityManagerLifecycleBoundaryTests {
    @Test
    func refreshesAreTrackedAndGuardedByRequestIDAcrossActivityKitAwaits() throws {
        let source = try source(
            at: sourceRoot().appendingPathComponent("VVTerm/Features/TerminalSessions/Application/LiveActivityManager.swift")
        )

        #expect(
            source.contains("private var refreshTask: Task<Void, Never>?"),
            "Live Activity refresh should store the in-flight task so newer refreshes can cancel it."
        )
        #expect(
            source.contains("private var refreshRequestID: UUID?"),
            "Live Activity refresh should carry a request ID across ActivityKit awaits."
        )
        #expect(
            source.contains("refreshTask?.cancel()"),
            "A newer refresh should cancel the previous refresh task before starting."
        )
        #expect(
            source.contains("await updateActivity(for: snapshots, requestID: requestID)"),
            "Refresh tasks should pass their request ID into the async ActivityKit update path."
        )
        #expect(
            source.contains("private func endAllActivities(requestID: UUID) async"),
            "Ending activities should be guarded by the same request ID as updateActivity."
        )
        #expect(
            source.contains("guard isCurrentRefresh(requestID) else { return }"),
            "ActivityKit await boundaries should re-check that the refresh request is still current."
        )
        #expect(
            !source.contains("Task {\n                await updateActivity(for: snapshots)"),
            "Refresh must not launch an untracked ActivityKit update task."
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

    private enum SourceRootError: Error {
        case notFound
    }
}
