import Foundation
import Testing

// Test Context:
// These source-boundary tests protect TerminalSessions Application dependency
// ownership. Runtime start and reconnect flows need server metadata, but that
// lookup should route through manager-level dependency providers instead of
// scattering direct Servers feature singleton reads across lifecycle files.
// Update these tests only when the server lookup owner intentionally changes.

struct TerminalSessionDependencyBoundaryTests {
    @Test
    func connectionSessionRuntimeAndReconnectUseInjectedServerProvider() throws {
        let root = try sourceRoot()
        let managerSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/ConnectionSessionManager.swift")
        )
        let runtimeSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/ConnectionSessionManager+Runtime.swift")
        )
        let reconnectSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/ConnectionSessionManager+Reconnect.swift")
        )

        // Given session runtime/reconnect flows need a Server for a session ID.
        #expect(managerSource.contains("typealias ServerProvider"))
        #expect(managerSource.contains("var serverProvider: ServerProvider"))
        #expect(runtimeSource.contains("serverProvider(session.serverId)"))
        #expect(reconnectSource.contains("serverProvider(session.serverId)"))

        // Then those lifecycle files do not reach directly into Servers state.
        #expect(!runtimeSource.contains("ServerManager.shared.servers"))
        #expect(!reconnectSource.contains("ServerManager.shared.servers"))
    }

    @Test
    func terminalTabRuntimeUsesInjectedServerProvider() throws {
        let root = try sourceRoot()
        let managerSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/TerminalTabManager.swift")
        )
        let runtimeSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/TerminalTabManager+Runtime.swift")
        )

        // Given split-pane runtime startup also needs server metadata.
        #expect(managerSource.contains("typealias ServerProvider"))
        #expect(managerSource.contains("var serverProvider: ServerProvider"))
        #expect(runtimeSource.contains("serverProvider(paneState.serverId)"))

        // Then pane runtime startup does not reach directly into Servers state.
        #expect(!runtimeSource.contains("ServerManager.shared.servers"))
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
