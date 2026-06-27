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

    @Test
    func serverFormConnectionTestHelperCancelsActiveRequestAndGuardsCallbacks() throws {
        // Given the server form SwiftUI source.
        let root = try sourceRoot()
        let source = try source(
            at: root.appendingPathComponent("VVTerm/Features/Servers/UI/ServerDetail/ServerFormSheet.swift")
        )

        // When the test isolates the connection-test lifecycle helpers.
        let requestSource = try slice(
            startingAt: "private func resetConnectionTestState()",
            endingBefore: "\n    private func saveServer",
            in: source
        )

        // Then the form keeps only request identity/presentation state while
        // cancellation stays delegated to the application-layer tester.
        #expect(requestSource.contains("activeConnectionTestRequestID"))
        #expect(requestSource.contains("connectionTester.cancelConnectionTestRequest"))
        #expect(
            requestSource.contains("connectionTester.requestConnectionTest(")
                && requestSource.contains("id: requestID"),
            "ServerFormSheet should create a stable request ID before registering callbacks."
        )

        // And stale success/failure/completion callbacks from an old field
        // snapshot must not update the current form state.
        #expect(
            requestSource.contains("activeConnectionTestRequestID == requestID"),
            "Connection-test callbacks should guard that the callback belongs to the active request."
        )
        #expect(
            requestSource.contains("connectionSnapshot == snapshot"),
            "Connection-test success and failure callbacks should guard against stale field snapshots."
        )
    }

    @Test
    func serverFormConnectionTesterIsExplicitlyInjected() throws {
        // Given the form and every current UI entry point that presents it.
        let root = try sourceRoot()
        let formSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/Servers/UI/ServerDetail/ServerFormSheet.swift")
        )
        let callerSources = try [
            "VVTerm/Features/Servers/UI/Sidebar/ServerSidebarView.swift",
            "VVTerm/Features/Servers/UI/iOS/iOSServerListView.swift",
            "VVTerm/Features/TerminalSessions/UI/Tabs/ConnectionTabsView.swift",
            "VVTerm/Features/TerminalSessions/UI/iOS/IOSTerminalPresentationHost.swift"
        ].map { path in
            try source(at: root.appendingPathComponent(path))
        }.joined(separator: "\n")

        // Then the form cannot silently resolve the global tester; callers must
        // pass the application-layer owner explicitly through the UI boundary.
        #expect(
            formSource.contains("connectionTester: ServerConnectionTester,"),
            "ServerFormSheet initializers should require an explicit ServerConnectionTester."
        )
        #expect(
            !formSource.contains("connectionTester: .shared"),
            "ServerFormSheet should not default connection testing to ServerConnectionTester.shared."
        )
        #expect(
            !formSource.contains("connectionTester: ServerConnectionTester ="),
            "ServerFormSheet should not provide a default connection tester argument."
        )
        #expect(
            callerSources.contains("connectionTester: connectionTester"),
            "ServerFormSheet callers should pass the existing connection tester dependency through."
        )
    }

    @Test
    func operationTesterUsesInjectedTransportServices() throws {
        // Given the Servers Application connection-test owner source.
        let root = try sourceRoot()
        let testerSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/Servers/Application/ServerConnectionTester.swift")
        )

        let operationTesterSource = try slice(
            startingAt: "final class ServerConnectionOperationTester",
            endingBefore: "\n}\n\nfinal class LiveServerConnectionMoshBootstrapper",
            in: testerSource
        )
        let operationSource = try tail(
            startingAt: "    func testConnection(server: Server, credentials: ServerCredentials) async throws {",
            in: operationTesterSource
        )

        // Then the live operation path depends on injected service protocols
        // instead of resolving Core SSH/mosh singletons at the use site.
        #expect(testerSource.contains("protocol ServerConnectionOperationServing"))
        #expect(testerSource.contains("protocol ServerConnectionMoshBootstrapping"))
        #expect(operationSource.contains("connectionService.withTemporaryConnection("))
        #expect(operationSource.contains("moshBootstrapper.bootstrapConnectInfo("))
        #expect(
            !operationSource.contains("SSHConnectionOperationService.shared"),
            "ServerConnectionOperationTester.testConnection should use its injected temporary connection service."
        )
        #expect(
            !operationSource.contains("RemoteMoshManager.shared"),
            "ServerConnectionOperationTester.testConnection should use its injected mosh bootstrapper."
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

    private func tail(startingAt marker: String, in source: String) throws -> String {
        guard let start = source.range(of: marker) else {
            throw SourceSliceError.notFound
        }
        return String(source[start.lowerBound..<source.endIndex])
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
