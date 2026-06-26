import Foundation
import Testing

// Test Context:
// These source-boundary tests protect the macOS Servers sidebar as a root
// composition view. Support and footer presentation can live in sibling views,
// while server selection, connection opening, sheet routing, and save handling
// should remain owned by the sidebar root or application-layer managers. Update
// these tests only when the Servers sidebar ownership boundary intentionally
// changes.
@Suite
struct ServerSidebarSuperfileBoundaryTests {
    @Test
    func serverSidebarComposesSupportViewsWithoutOwningTheirLayout() throws {
        let root = try sourceRoot()
        let sidebarSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/Servers/UI/Sidebar/ServerSidebarView.swift")
        )
        let supportSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/Servers/UI/Sidebar/ServerSidebarSupportViews.swift")
        )

        // Given ServerSidebarView is the macOS sidebar root.
        for component in [
            "ServerSidebarSupportBanner",
            "ServerSidebarFooterButtons"
        ] {
            #expect(
                sidebarSource.contains("\(component)("),
                "ServerSidebarView.swift should compose \(component)."
            )
            #expect(
                !sidebarSource.contains("struct \(component)"),
                "ServerSidebarView.swift should not define \(component)."
            )
            #expect(
                supportSource.contains("struct \(component)"),
                "ServerSidebarSupportViews.swift should define \(component)."
            )
        }

        for helperName in [
            "supportBanner",
            "footerButtons"
        ] {
            #expect(
                !sidebarSource.contains("private var \(helperName)"),
                "ServerSidebarView.swift should not own \(helperName) presentation helper."
            )
        }
    }

    @Test
    func serverSidebarSupportViewsDoNotOwnLifecycleOrSaveIntent() throws {
        let root = try sourceRoot()
        let sidebarSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/Servers/UI/Sidebar/ServerSidebarView.swift")
        )
        let supportSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/Servers/UI/Sidebar/ServerSidebarSupportViews.swift")
        )

        // Then support/footer presentation remains a leaf UI extraction.
        #expect(
            sidebarSource.contains("requestServerTerminalOpen("),
            "ServerSidebarView.swift should keep terminal-open intent at the sidebar root."
        )
        #expect(
            sidebarSource.contains("handleSavedServer("),
            "ServerSidebarView.swift should keep post-save selection/filter handling at the sidebar root."
        )
        #expect(
            !supportSource.contains("requestServerTerminalOpen("),
            "ServerSidebarSupportViews.swift should not own terminal-open orchestration."
        )
        #expect(
            !supportSource.contains("handleSavedServer("),
            "ServerSidebarSupportViews.swift should not own post-save handling."
        )
        #expect(
            !supportSource.contains("ServerManager"),
            "ServerSidebarSupportViews.swift should not depend on Servers application managers."
        )
        #expect(
            !supportSource.contains("TerminalTabManager"),
            "ServerSidebarSupportViews.swift should not depend on TerminalSessions managers."
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
