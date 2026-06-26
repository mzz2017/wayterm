import Foundation
import Testing

// Test Context:
// These source-boundary tests protect RemoteTmuxManager superfile control.
// RemoteTmuxManager owns remote command execution, backend detection, and
// lifecycle timeouts; pure tmux list-session parsing belongs in a separate
// parser so parsing policy can be tested without actor or SSH execution.
// Update only if parser ownership intentionally moves to another non-actor
// SSH/Core type.
@Suite
struct RemoteTmuxManagerSuperfileBoundaryTests {
    @Test
    func managerDoesNotOwnSessionListParsingPolicy() throws {
        let root = try sourceRoot()
        let managerSource = try source(
            at: root.appendingPathComponent("VVTerm/Core/SSH/RemoteTmuxManager.swift")
        )
        let parserSource = try source(
            at: root.appendingPathComponent("VVTerm/Core/SSH/RemoteTmuxSessionListParser.swift")
        )

        #expect(
            managerSource.contains("sessionListParser.parse"),
            "RemoteTmuxManager should delegate session-list parsing to RemoteTmuxSessionListParser."
        )
        #expect(
            parserSource.contains("struct RemoteTmuxSessionListParser"),
            "RemoteTmuxSessionListParser.swift should own tmux session-list parsing."
        )

        #expect(
            parserSource.contains("func parse("),
            "RemoteTmuxSessionListParser.swift should expose the session-list parse entry point."
        )

        for functionName in [
            "parseSessionLine",
            "parseTabSeparatedSessionLine",
            "parseAttachedClients",
            "parseLegacySessionLine",
            "sortSessions"
        ] {
            #expect(
                !managerSource.contains("func \(functionName)"),
                "RemoteTmuxManager.swift should not own \(functionName)."
            )
            #expect(
                parserSource.contains("func \(functionName)"),
                "RemoteTmuxSessionListParser.swift should own parsing behavior."
            )
        }

        #expect(
            !managerSource.contains("func parseSessionListOutput"),
            "RemoteTmuxManager.swift should not expose parser policy as actor API."
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
