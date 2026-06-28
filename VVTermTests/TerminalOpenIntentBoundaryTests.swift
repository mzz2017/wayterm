import Foundation
import Testing

// Test Context:
// These tests protect the terminal open workflow that previously surfaced as
// confusing SSH/auth failures when users closed or reopened tabs quickly. UI may
// select views, show spinners, and present alerts, but terminal tab/session open
// work must be owned by TerminalSessions application managers so duplicate-open
// gates, teardown waits, and open failures remain tracked. Update these tests
// only when terminal open ownership intentionally moves to another application
// owner with equivalent request tracking and failure propagation.
@Suite
struct TerminalOpenIntentBoundaryTests {
    @Test
    func terminalOpenUIUsesApplicationOpenIntentRequests() throws {
        // Given SwiftUI files that expose terminal open entry points.
        let root = try sourceRoot()
        let sources = try terminalOpenUISources(root: root)

        // Then those views must not own the async open operation directly. A
        // synchronous request API keeps open lifecycle state in the manager
        // instead of splitting it between SwiftUI tasks and application state.
        #expect(
            !sources.contains("try? await tabManager.openTab"),
            "SwiftUI should not swallow tab open failures with try?."
        )
        #expect(
            !sources.contains("try await tabManager.openTab"),
            "SwiftUI should send tab-open intent to TerminalTabManager instead of awaiting openTab directly."
        )
        #expect(
            !sources.contains("try? await sessionManager.openConnection"),
            "SwiftUI should not swallow session open failures with try?."
        )
        #expect(
            !sources.contains("try await sessionManager.openConnection"),
            "SwiftUI should send session-open intent to ConnectionSessionManager instead of awaiting openConnection directly."
        )
    }

    @Test
    func terminalOpenUIDoesNotUseNoOpOpenFailureCatch() throws {
        // Given SwiftUI files that expose terminal open entry points.
        let root = try sourceRoot()
        let sources = try terminalOpenUISources(root: root)

        // Then an open failure must be recorded or surfaced by the application
        // owner instead of disappearing in a no-op catch path.
        #expect(
            !sources.contains("No-op: user cancelled biometric auth or open failed."),
            "Terminal open failures must not be hidden behind a no-op UI catch."
        )
    }

    @Test
    func terminalOpenUIDoesNotBranchAroundApplicationOwnerForExistingTabs() throws {
        // Given SwiftUI files that expose terminal open entry points.
        let root = try sourceRoot()
        let sources = try terminalOpenUISources(root: root)

        // Then existing-tab selection must still go through the application
        // owner so app-lock gates, teardown ordering, and failure state cannot
        // be bypassed by a UI-side empty-tabs branch.
        #expect(
            !sources.contains("tabs(for: server.id).isEmpty"),
            "SwiftUI should not branch around TerminalTabManager when opening or focusing a terminal tab."
        )
    }

    @Test
    func terminalOpenUIDoesNotPreselectServerBeforeManagerUnlocks() throws {
        // Given the macOS server sidebar terminal-open entry point.
        let root = try sourceRoot()
        let source = try source(
            at: root.appendingPathComponent("VVTerm/Features/Servers/UI/Sidebar/ServerSidebarView.swift")
        )

        // Then selecting the server must be done from the manager success
        // callback. Preselecting before the request can reveal an existing
        // locked terminal tab before AppLock finishes.
        #expect(
            !source.contains("selectedServer = server\n        tabManager.requestServerTerminalOpen"),
            "ServerSidebarView should select a server only after TerminalTabManager reports open/focus success."
        )
    }

    private func terminalOpenUISources(root: URL) throws -> String {
        let paths = [
            "VVTerm/App/ContentView.swift",
            "VVTerm/Core/UI/SidebarComponents.swift",
            "VVTerm/Features/Servers/UI/Sidebar/ServerSidebarRow.swift",
            "VVTerm/Features/Servers/UI/Sidebar/ServerSidebarView.swift",
            "VVTerm/Features/TerminalSessions/UI/Tabs/ConnectionTabsView.swift",
            "VVTerm/App/iOS/iOSContentView.swift"
        ]

        return try paths
            .map { try source(at: root.appendingPathComponent($0)) }
            .joined(separator: "\n")
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
