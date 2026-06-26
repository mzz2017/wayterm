import Foundation
import Testing

// Test Context:
// These source-boundary tests protect TerminalTabManager superfile control.
// The manager owns tab orchestration; Codable persistence snapshot shape should
// live in a dedicated Application support file. Update only when snapshot
// ownership intentionally moves again.

@Suite(.serialized)
struct TerminalTabManagerSuperfileBoundaryTests {
    @Test
    func persistenceSnapshotLivesOutsideTerminalTabManagerFile() throws {
        let root = try sourceRoot()
        let managerSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/TerminalTabManager.swift")
        )
        let snapshotSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/TerminalTabsSnapshot.swift")
        )

        // Given the terminal tab manager source.
        #expect(
            !managerSource.contains("struct TerminalTabsSnapshot"),
            "TerminalTabManager.swift should not own Codable persistence snapshot shape."
        )

        // Then tab persistence serialization has a dedicated Application file.
        #expect(snapshotSource.contains("struct TerminalTabsSnapshot"))
        #expect(snapshotSource.contains("struct ServerSnapshot"))
        #expect(snapshotSource.contains("struct TabSnapshot"))
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
