import Foundation
import Testing

// Test Context:
// Native find bridges UIKit's UIFindInteraction with Ghostty search state on iOS.
// GhosttyTerminalView may route delegate callbacks and UITextSearching snapshots,
// but the native find session and reported Ghostty result counters should live in
// a focused runtime owner. Update this test only if native find ownership moves
// to another explicit runtime/application boundary.

@Suite(.serialized)
struct GhosttyIOSFindRuntimeBoundaryTests {
    @Test
    func iOSTerminalViewDelegatesNativeFindSessionStateToRuntimeOwner() throws {
        let root = try sourceRoot()
        let viewSource = try source(
            at: root.appendingPathComponent("VVTerm/GhosttyTerminal/GhosttyTerminalView+iOS.swift")
        )
        let runtimeSource = try source(
            at: root.appendingPathComponent("VVTerm/GhosttyTerminal/TerminalIOSFindRuntime.swift")
        )

        // Given GhosttyTerminalView owns UIKit delegate routing but not find
        // session/result bookkeeping.
        #expect(viewSource.contains("private let findRuntime = TerminalIOSFindRuntime()"))
        #expect(viewSource.contains("findRuntime.makeSession"))
        #expect(viewSource.contains("findRuntime.applyExternalQuery"))
        #expect(viewSource.contains("findRuntime.updateReportedTotal"))
        #expect(viewSource.contains("findRuntime.updateReportedSelectedIndex"))
        #expect(viewSource.contains("findRuntime.resetReportedResults"))

        // Then session ownership and Ghostty result counters must not stay in
        // the giant iOS terminal view.
        #expect(!viewSource.contains("private var nativeFindSession"))
        #expect(!viewSource.contains("private var ghosttyFindReportedTotal"))
        #expect(!viewSource.contains("private var ghosttyFindReportedSelectedIndex"))
        #expect(!viewSource.contains("private func applyStoredGhosttyFindResultsToNativeSession"))

        // And the focused runtime owns the stored session and result reporting API.
        #expect(runtimeSource.contains("final class TerminalIOSFindRuntime"))
        #expect(runtimeSource.contains("private var nativeFindSession"))
        #expect(runtimeSource.contains("private var ghosttyFindReportedTotal"))
        #expect(runtimeSource.contains("private var ghosttyFindReportedSelectedIndex"))
        #expect(runtimeSource.contains("func makeSession"))
        #expect(runtimeSource.contains("func applyExternalQuery"))
        #expect(runtimeSource.contains("func updateReportedTotal"))
        #expect(runtimeSource.contains("func updateReportedSelectedIndex"))
        #expect(runtimeSource.contains("func resetReportedResults"))
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
