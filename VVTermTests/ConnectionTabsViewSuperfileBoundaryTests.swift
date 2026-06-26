import Foundation
import Testing

// Test Context:
// These source-boundary tests protect TerminalSessions tab container superfile
// control. ConnectionTabsView owns server-scoped terminal/files composition and
// intent routing; reusable tab chrome and macOS window chrome components should
// live in sibling UI files so macOS tab presentation does not inflate the
// container root.
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

    @Test
    func connectionTabsViewComposesMacOSChromeWithoutOwningWindowObserver() throws {
        let root = try sourceRoot()
        let containerSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/UI/Tabs/ConnectionTabsView.swift")
        )
        let chromeSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/UI/Tabs/ConnectionTabsMacOSChrome.swift")
        )

        // Given ConnectionTabsView owns macOS terminal tab composition.
        #expect(
            containerSource.contains("MacOSZenWindowChromeBridge("),
            "ConnectionTabsView.swift should compose the macOS zen chrome bridge."
        )
        #expect(
            containerSource.contains("MacOSToolbarBackdrop("),
            "ConnectionTabsView.swift should compose the macOS toolbar backdrop."
        )

        // Then window-observer and toolbar-backdrop implementation details
        // should live in a sibling file instead of the container root.
        #expect(
            !containerSource.contains("struct MacOSZenWindowChromeBridge: NSViewRepresentable"),
            "ConnectionTabsView.swift should not define the macOS zen chrome bridge."
        )
        #expect(
            !containerSource.contains("final class WindowObserverView: NSView"),
            "ConnectionTabsView.swift should not own the macOS window observer view."
        )
        #expect(
            !containerSource.contains("struct MacOSToolbarBackdrop: View"),
            "ConnectionTabsView.swift should not define macOS toolbar backdrop chrome."
        )
        #expect(
            chromeSource.contains("struct MacOSZenWindowChromeBridge: NSViewRepresentable"),
            "ConnectionTabsMacOSChrome.swift should define the macOS zen chrome bridge."
        )
        #expect(
            chromeSource.contains("final class WindowObserverView: NSView"),
            "ConnectionTabsMacOSChrome.swift should own the macOS window observer view."
        )
        #expect(
            chromeSource.contains("struct MacOSToolbarBackdrop: View"),
            "ConnectionTabsMacOSChrome.swift should define macOS toolbar backdrop chrome."
        )
    }

    @Test
    func connectionTabsViewComposesToolbarContentWithoutOwningToolbarItems() throws {
        let root = try sourceRoot()
        let containerSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/UI/Tabs/ConnectionTabsView.swift")
        )
        let toolbarSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/UI/Tabs/ConnectionTabsToolbarContent.swift")
        )

        // Given ConnectionTabsView owns server-scoped lifecycle intent routing.
        #expect(
            containerSource.contains("ConnectionTabsToolbarContent("),
            "ConnectionTabsView.swift should compose the macOS toolbar content."
        )

        // Then toolbar item layout should live in a sibling UI component so the
        // container root stays focused on composition and intent routing.
        #expect(
            !containerSource.contains("ToolbarItem(placement:"),
            "ConnectionTabsView.swift should not own concrete macOS toolbar items."
        )
        #expect(
            toolbarSource.contains("struct ConnectionTabsToolbarContent: ToolbarContent"),
            "ConnectionTabsToolbarContent.swift should define the toolbar content component."
        )
        #expect(
            toolbarSource.contains("ToolbarItem(placement:"),
            "ConnectionTabsToolbarContent.swift should own concrete macOS toolbar items."
        )

        for lifecycleCall in [
            "requestTabOpen(",
            "requestServerDisconnect(",
            "disconnectServerAndWait",
            "splitFocusedPane(",
            "splitHorizontal(",
            "splitVertical("
        ] {
            #expect(
                !toolbarSource.contains(lifecycleCall),
                "ConnectionTabsToolbarContent.swift should receive lifecycle actions as closures, not call \(lifecycleCall)."
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
