import Foundation
import Testing

// Test Context:
// These tests protect RemoteFiles UI/Application ownership for user-triggered
// directory navigation and entry activation. SwiftUI may adapt gestures,
// buttons, refresh controls, and preview presentation, but the application
// store must own remote SFTP navigation task lifetime, stale-result ordering,
// and cancellation. The tests inspect source placement only; update them only
// when navigation request ownership intentionally moves to another
// application-layer owner.
@Suite
struct RemoteFileNavigationIntentBoundaryTests {
    @Test
    func browserScreenDelegatesNavigationTaskOwnershipToStore() throws {
        // Given the shared RemoteFiles browser SwiftUI source.
        let root = try sourceRoot()
        let source = try source(
            at: root.appendingPathComponent("VVTerm/Features/RemoteFiles/UI/RemoteFileBrowserScreen.swift")
        )

        // Then initial load, entry open, entry activation, and breadcrumb
        // navigation must send intent to the store request API instead of
        // owning async navigation tasks in SwiftUI.
        #expect(
            source.contains("browser.requestNavigation("),
            "RemoteFileBrowserScreen should delegate navigation task ownership to RemoteFileBrowserStore.requestNavigation."
        )
        #expect(
            !containsRegex(#"await\s+browser\.loadInitialPath"#, in: source),
            "RemoteFileBrowserScreen should not directly await initial remote directory loading from SwiftUI."
        )
        #expect(
            !containsRegex(#"Task\s*(?:\([^)]*\))?\s*\{\s*await\s+browser\.(openDirectory|activate|openBreadcrumb)"#, in: source),
            "RemoteFileBrowserScreen should not own Task wrappers around directory open, activation, or breadcrumbs."
        )
        #expect(
            !containsRegex(#"await\s+browser\.(openDirectory|activate|openBreadcrumb)"#, in: source),
            "RemoteFileBrowserScreen should not directly await async navigation helpers."
        )
        #expect(
            source.contains("onCompleted: { result in"),
            "Navigation-dependent flows such as macOS inline folder creation should continue from requestNavigation completion."
        )
        #expect(
            !containsRegex(#"Task\s*\{\s*if\s+snapshot\.currentPath\s*!=\s*destinationPath[\s\S]*browser\.requestNavigation[\s\S]*browser\.createDirectory"#, in: source),
            "RemoteFileBrowserScreen should not fire navigation intent and then continue folder creation before navigation completion."
        )
    }

    @Test
    func platformScreensDelegateNavigationTaskOwnershipToStore() throws {
        // Given iOS and macOS RemoteFiles browser platform sources.
        let root = try sourceRoot()
        let platformSource = try [
            "VVTerm/Features/RemoteFiles/UI/RemoteFileBrowserIOSScreen.swift",
            "VVTerm/Features/RemoteFiles/UI/RemoteFileBrowserMacScreen.swift"
        ].map { path in
            try source(at: root.appendingPathComponent(path))
        }.joined(separator: "\n")

        // Then refresh, go up, activation, breadcrumb, and directory-open
        // controls must delegate remote navigation task lifetime to the store.
        #expect(
            platformSource.contains("browser.requestNavigation("),
            "RemoteFileBrowser platform views should send navigation intent through requestNavigation."
        )
        #expect(
            !containsRegex(#"Task\s*(?:\([^)]*\))?\s*\{\s*await\s+browser\.(goUp|refresh|activate|openBreadcrumb|openDirectory)"#, in: platformSource),
            "RemoteFileBrowser platform views should not own Task wrappers around navigation helpers."
        )
        #expect(
            !containsRegex(#"await\s+browser\.(goUp|refresh|activate|openBreadcrumb|openDirectory)"#, in: platformSource),
            "RemoteFileBrowser platform views should not directly await async navigation helpers."
        )
    }

    @Test
    func tabChromeDelegatesRemoteFileNavigationTaskOwnershipToStore() throws {
        // Given TerminalSessions tab chrome hosts RemoteFiles toolbar controls.
        let root = try sourceRoot()
        let source = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/UI/Tabs/ConnectionTabsView.swift")
        )

        // Then tab chrome should send RemoteFiles navigation intent through the
        // store instead of starting toolbar-owned go-up or refresh tasks.
        #expect(
            source.contains("fileBrowser.requestNavigation("),
            "ConnectionTabsView RemoteFiles controls should delegate navigation task ownership to RemoteFileBrowserStore."
        )
        #expect(
            !containsRegex(#"Task\s*(?:\([^)]*\))?\s*\{\s*await\s+fileBrowser\.(goUp|refresh)"#, in: source),
            "ConnectionTabsView should not own Task wrappers around RemoteFiles go-up or refresh."
        )
        #expect(
            !containsRegex(#"await\s+fileBrowser\.(goUp|refresh)"#, in: source),
            "ConnectionTabsView should not directly await RemoteFiles navigation helpers."
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

    private func containsRegex(_ pattern: String, in source: String) -> Bool {
        source.range(of: pattern, options: .regularExpression) != nil
    }

    private enum SourceRootError: Error {
        case notFound
    }
}
