import Foundation
import Testing

// Test Context:
// These tests protect ServerFormSheet's UI/Application boundary for
// user-initiated connection tests. The form may build a draft server,
// credentials, and UI messages, but temporary SSH/mosh lifecycle work must be
// owned by Servers Application. The tests inspect source placement only; update
// this context only when connection-test ownership intentionally moves to
// another application-layer owner.
@Suite
struct ServerFormConnectionTestBoundaryTests {
    @Test
    func serverFormConnectionButtonSendsIntentWithoutOwningTask() throws {
        // Given the server form SwiftUI source.
        let root = try sourceRoot()
        let source = try source(
            at: root.appendingPathComponent("VVTerm/Features/Servers/UI/ServerDetail/ServerFormSheet.swift")
        )

        // When the test isolates the connection section button.
        let connectionSectionSource = try slice(
            startingAt: "private var connectionSection",
            endingBefore: "\n    private var sessionSection",
            in: source
        )

        // Then the button must synchronously send intent instead of launching
        // SwiftUI-owned connection-test work.
        #expect(
            !connectionSectionSource.contains("Task {"),
            "ServerFormSheet connection button should not own connection-test Task state."
        )
        #expect(
            connectionSectionSource.contains("requestConnectionTest(force: true)"),
            "ServerFormSheet connection button should send intent through the request helper."
        )
    }

    @Test
    func serverFormConnectionTestHelperDelegatesTemporaryTransportWork() throws {
        // Given the server form SwiftUI source.
        let root = try sourceRoot()
        let source = try source(
            at: root.appendingPathComponent("VVTerm/Features/Servers/UI/ServerDetail/ServerFormSheet.swift")
        )

        // When the test isolates the connection-test request helper.
        let requestSource = try slice(
            startingAt: "private func requestConnectionTest(force: Bool)",
            endingBefore: "\n    private func saveServer",
            in: source
        )

        // Then the helper must not own detached SSH work or directly touch Core
        // SSH/mosh singleton services.
        #expect(
            !requestSource.contains("Task.detached"),
            "ServerFormSheet should not detach temporary connection-test SSH work."
        )
        #expect(
            !requestSource.contains("SSHConnectionOperationService.shared"),
            "ServerFormSheet should delegate temporary SSH connection checks to Servers Application."
        )
        #expect(
            !requestSource.contains("RemoteMoshManager.shared"),
            "ServerFormSheet should delegate mosh bootstrap checks to Servers Application."
        )
        #expect(
            requestSource.contains("connectionTester.requestConnectionTest("),
            "ServerFormSheet should call the application-layer connection tester."
        )
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
