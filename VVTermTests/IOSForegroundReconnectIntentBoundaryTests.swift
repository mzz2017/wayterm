import Foundation
import Testing

// Test Context:
// Protected behavior: iOS foreground, scene-active, and selection refresh may
// update presentation state from a callback, but reconnect execution must be
// owned and tracked by ConnectionSessionManager.
// Target invariant: attemptForegroundReconnectIfNeeded(refreshTerminal:) must
// call requestForegroundReconnectForSelectedSession(...) and must not create a
// local Task or call the lower-level async foreground reconnect helper.
// Fake assumptions: this is source-boundary coverage because the protected
// behavior is SwiftUI/application ownership; manager request ordering is covered
// by ConnectionLifecycleIntegrationTests.
// Update guidance: update this test only if foreground reconnect ownership
// intentionally moves to another non-UI application owner.
@Suite(.serialized)
struct IOSForegroundReconnectIntentBoundaryTests {
    @Test
    func foregroundReconnectHelperSendsTrackedManagerRequest() throws {
        let root = try sourceRoot()
        let source = try source(at: root.appendingPathComponent("VVTerm/App/iOS/iOSContentView.swift"))
        let helper = try slice(
            startingAt: "private func attemptForegroundReconnectIfNeeded",
            endingBefore: "\n    var body:",
            in: source
        )

        // Given iOS foreground reconnect is triggered by SwiftUI lifecycle and
        // selection events.
        #expect(
            helper.contains("sessionManager.requestForegroundReconnectForSelectedSession"),
            "Foreground reconnect should send tracked intent to ConnectionSessionManager."
        )

        // Then SwiftUI must not own the async reconnect sequence.
        #expect(helper.range(of: #"Task\s*\{"#, options: .regularExpression) == nil)
        #expect(!helper.contains("handleForegroundReconnectForSelectedSession"))
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
