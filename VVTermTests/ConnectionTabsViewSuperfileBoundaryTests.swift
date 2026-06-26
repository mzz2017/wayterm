import Foundation
import Testing

// Test Context:
// These source-boundary tests protect TerminalSessions tab container superfile
// control. ConnectionTabsView owns server-scoped terminal/files composition and
// intent routing; reusable tab chrome components should live in sibling UI
// files so macOS tab presentation does not inflate the container root.
@Suite
struct ConnectionTabsViewSuperfileBoundaryTests {
    @Test
    func connectionTabsViewDoesNotOwnTerminalTabChromeComponents() throws {
        let root = try sourceRoot()
        let containerSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/UI/Tabs/ConnectionTabsView.swift")
        )
        let componentSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/UI/Tabs/TerminalTabComponents.swift")
        )

        for typeName in [
            "TerminalTabsScrollView",
            "TerminalTabButton"
        ] {
            #expect(
                !containerSource.contains("struct \(typeName)"),
                "ConnectionTabsView.swift should not define \(typeName)."
            )
            #expect(
                componentSource.contains("struct \(typeName)"),
                "TerminalTabComponents.swift should define \(typeName)."
            )
        }
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
