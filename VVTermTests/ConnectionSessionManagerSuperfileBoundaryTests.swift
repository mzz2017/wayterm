import Foundation
import Testing

// Test Context:
// These source-boundary tests protect TerminalSessions Application superfile
// control. ConnectionSessionManager owns orchestration; shared lifecycle value
// types and persistence snapshots should live in dedicated support files so
// future connection behavior changes do not expand the manager superfile.
// Update only when this ownership intentionally moves again.

@Suite(.serialized)
struct ConnectionSessionManagerSuperfileBoundaryTests {
    @Test
    func lifecycleSupportTypesLiveOutsideConnectionSessionManagerFile() throws {
        let root = try sourceRoot()
        let managerSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/ConnectionSessionManager.swift")
        )
        let supportSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/TerminalSessionLifecycleTypes.swift")
        )

        // Given the terminal session manager source.
        #expect(
            !managerSource.contains("enum ShellTeardownMode"),
            "ConnectionSessionManager.swift should not own shared shell teardown mode types."
        )
        #expect(
            !managerSource.contains("struct TerminalSurfaceAttachContext"),
            "ConnectionSessionManager.swift should not own shared terminal surface attach context types."
        )

        // Then shared lifecycle value types have a dedicated Application file.
        #expect(supportSource.contains("enum ShellTeardownMode"))
        #expect(supportSource.contains("enum TerminalSurfaceDetachReason"))
        #expect(supportSource.contains("struct TerminalSurfaceAttachContext"))
        #expect(supportSource.contains("struct TerminalResizeRequestSize"))
    }

    @Test
    func persistenceSnapshotLivesOutsideConnectionSessionManagerFile() throws {
        let root = try sourceRoot()
        let managerSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/ConnectionSessionManager.swift")
        )
        let snapshotSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/ConnectionSessionsSnapshot.swift")
        )

        // Given the terminal session manager source.
        #expect(
            !managerSource.contains("struct ConnectionSessionsSnapshot"),
            "ConnectionSessionManager.swift should not own Codable persistence snapshot shape."
        )

        // Then session persistence serialization has a dedicated Application file.
        #expect(snapshotSource.contains("struct ConnectionSessionsSnapshot"))
        #expect(snapshotSource.contains("struct SessionSnapshot"))
        #expect(snapshotSource.contains("struct ServerSnapshot"))
    }

    @Test
    func supportTypesLiveOutsideConnectionSessionManagerFile() throws {
        let root = try sourceRoot()
        let managerSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/ConnectionSessionManager.swift")
        )
        let supportSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/ConnectionSessionManagerSupport.swift")
        )

        // Given the connection session manager source.
        #expect(
            !managerSource.contains("struct SessionCloseResult"),
            "ConnectionSessionManager.swift should not own session close result support shape."
        )
        #expect(
            !managerSource.contains("struct ForegroundReconnectRequest"),
            "ConnectionSessionManager.swift should not own foreground reconnect request shape."
        )
        #expect(
            !managerSource.contains("final class SessionRuntimeState"),
            "ConnectionSessionManager.swift should not own session runtime support storage."
        )

        // Then session-manager-only support types have a dedicated Application file.
        #expect(supportSource.contains("enum ConnectionSessionManagerSupport"))
        #expect(supportSource.contains("struct SessionCloseResult"))
        #expect(supportSource.contains("struct ForegroundReconnectRequest"))
        #expect(supportSource.contains("final class SessionRuntimeState"))
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
