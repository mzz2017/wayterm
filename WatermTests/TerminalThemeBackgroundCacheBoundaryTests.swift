import Foundation
import Testing

// Test Context:
// Terminal surfaces need fast cached background colors during launch and theme
// changes, but UI views should not own UserDefaults cache keys or writes.
// These source-boundary tests protect the persistence boundary around
// TerminalThemeBackgroundResolver. Update them only when cache ownership moves
// intentionally to another non-UI service.
@Suite(.serialized)
struct TerminalThemeBackgroundCacheBoundaryTests {
    @Test
    func terminalSessionViewsDelegateBackgroundCachePersistenceToResolver() throws {
        let root = try sourceRoot()

        for relativePath in [
            "Waterm/Features/TerminalSessions/UI/iOS/iOSTerminalView.swift",
            "Waterm/Features/TerminalSessions/UI/Terminal/TerminalContainerView.swift",
            "Waterm/Features/TerminalSessions/UI/Splits/TerminalPaneView.swift",
            "Waterm/Features/TerminalSessions/UI/Tabs/ConnectionTabsView.swift"
        ] {
            let source = try source(at: root.appendingPathComponent(relativePath))

            #expect(
                !source.contains("TerminalThemeBackgroundResolver.cacheKey"),
                "\(relativePath) should not reference the terminal background cache key directly."
            )
            #expect(
                !source.contains("UserDefaults.standard.set("),
                "\(relativePath) should not write terminal background cache values directly."
            )
            #expect(
                source.contains("TerminalThemeBackgroundResolver.cacheResolvedBackground(")
                    || source.contains("TerminalThemeBackgroundResolver.cachedBackground("),
                "\(relativePath) should delegate terminal background cache access to the resolver."
            )
        }
    }

    private func source(at url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    private func sourceRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.lastPathComponent != "WatermTests" {
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
