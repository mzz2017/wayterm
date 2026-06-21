import Foundation
import Testing

// Test Context:
// These tests protect MoveServerSheet's UI/Application boundary for
// user-initiated server relocation between workspaces. Moving a server updates
// server metadata and workspace selection metadata together, so the SwiftUI
// sheet may validate selection state, but it must not own the async move task
// or call lower-level move APIs directly. Update this context only when server
// move ownership intentionally moves to another application-layer owner.
@Suite
struct ServerMoveIntentBoundaryTests {
    @Test
    func moveServerSheetSendsMoveIntentToServerManagerRequest() throws {
        // Given the server form SwiftUI source containing MoveServerSheet.
        let root = try sourceRoot()
        let source = try source(
            at: root.appendingPathComponent("VVTerm/Features/Servers/UI/ServerDetail/ServerFormSheet.swift")
        )

        // When the test isolates the MoveServerSheet moveServer implementation.
        let moveServerSource = try functionBody(
            named: "private func moveServer()",
            endingBefore: "\n    private func sectionHeader",
            in: source
        )

        // Then moveServer must call a request-style application API instead of
        // owning fire-and-forget async server move work.
        #expect(
            !moveServerSource.contains("Task {"),
            "MoveServerSheet.moveServer should not own async server move Task state."
        )
        #expect(
            !moveServerSource.contains("Task("),
            "MoveServerSheet.moveServer should not create Task-based server move work."
        )
        #expect(
            !moveServerSource.contains("Task.detached"),
            "MoveServerSheet.moveServer should not detach server move work from the application owner."
        )
        #expect(
            !moveServerSource.contains("serverManager.moveServer("),
            "MoveServerSheet.moveServer should call requestServerMove instead of moveServer directly."
        )
        #expect(
            moveServerSource.contains("serverManager.requestServerMove("),
            "MoveServerSheet.moveServer should synchronously send move intent through ServerManager."
        )
    }

    private func functionBody(named marker: String, endingBefore endMarker: String, in source: String) throws -> String {
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
