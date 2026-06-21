import Foundation
import Testing

// Test Context:
// These tests protect ServerFormSheet's UI/Application boundary for
// user-initiated server create and update saves. Server saves persist
// credentials and metadata together, so the SwiftUI form may validate and build
// draft values, but it must not own the async save task or call lower-level
// server CRUD methods directly. Update this context only when server form save
// ownership intentionally moves to another application-layer owner.
@Suite
struct ServerFormSaveIntentBoundaryTests {
    @Test
    func serverFormSendsSaveIntentToServerManagerRequest() throws {
        // Given the server form SwiftUI source.
        let root = try sourceRoot()
        let source = try source(
            at: root.appendingPathComponent("VVTerm/Features/Servers/UI/ServerDetail/ServerFormSheet.swift")
        )

        // When the test isolates the saveServer implementation.
        let saveServerSource = try functionBody(
            named: "private func saveServer()",
            endingBefore: "\n    }\n}\n\nstruct MoveServerSheet",
            in: source
        )

        // Then saveServer must call a request-style application API instead of
        // owning fire-and-forget async credential/metadata CRUD work.
        #expect(
            !saveServerSource.contains("Task {"),
            "ServerFormSheet.saveServer should not own async server save Task state."
        )
        #expect(
            !saveServerSource.contains("try await serverManager.updateServer(newServer, credentials: credentials)"),
            "ServerFormSheet.saveServer should call requestServerSave instead of updateServer directly."
        )
        #expect(
            !saveServerSource.contains("try await serverManager.addServer(newServer, credentials: credentials)"),
            "ServerFormSheet.saveServer should call requestServerSave instead of addServer directly."
        )
        #expect(
            saveServerSource.contains("serverManager.requestServerSave("),
            "ServerFormSheet.saveServer should synchronously send save intent through ServerManager."
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
