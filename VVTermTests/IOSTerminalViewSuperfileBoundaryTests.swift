import Foundation
import Testing

// Test Context:
// These source-boundary tests protect iOSTerminalView superfile control. The
// iOS terminal root owns top-level composition and intent routing; reusable
// floating controls, navigation toolbar chrome, and transient connection
// chrome should live in sibling UI files so the root view does not accumulate
// presentation subcomponents.
// Update this test only if iOS terminal root composition intentionally changes.
@Suite
struct IOSTerminalViewSuperfileBoundaryTests {
    @Test
    func iosTerminalViewDoesNotOwnFloatingControlOrConnectingChrome() throws {
        let root = try sourceRoot()
        let rootSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/UI/iOS/iOSTerminalView.swift")
        )
        let componentSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/UI/iOS/IOSTerminalFloatingControls.swift")
        )

        for typeName in [
            "IOSTerminalFloatingControls",
            "IOSTerminalConnectingStateView"
        ] {
            #expect(
                !rootSource.contains("struct \(typeName)"),
                "iOSTerminalView.swift should not define \(typeName)."
            )
            #expect(
                componentSource.contains("struct \(typeName)"),
                "IOSTerminalFloatingControls.swift should define \(typeName)."
            )
        }

        #expect(
            !rootSource.contains("private func floatingTerminalControlButton"),
            "iOSTerminalView.swift should not own floating control button chrome."
        )
    }

    @Test
    func iosTerminalViewComposesNavigationToolbarWithoutOwningToolbarChrome() throws {
        let root = try sourceRoot()
        let rootSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/UI/iOS/iOSTerminalView.swift")
        )
        let toolbarSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/UI/iOS/IOSTerminalNavigationToolbar.swift")
        )

        // Given iOSTerminalView owns terminal routing and state.
        #expect(
            rootSource.contains("IOSTerminalNavigationToolbar("),
            "iOSTerminalView.swift should compose the iOS terminal navigation toolbar."
        )

        // Then reusable navigation toolbar presentation should live in its own
        // sibling UI component rather than growing the terminal root view.
        #expect(
            !rootSource.contains("ToolbarItem(placement:"),
            "iOSTerminalView.swift should not own concrete navigation toolbar items."
        )
        #expect(
            !rootSource.contains("ToolbarItemGroup(placement:"),
            "iOSTerminalView.swift should not own concrete navigation toolbar groups."
        )
        #expect(
            toolbarSource.contains("struct IOSTerminalNavigationToolbar: ToolbarContent"),
            "IOSTerminalNavigationToolbar.swift should define the toolbar component."
        )
        #expect(
            toolbarSource.contains("ToolbarItemGroup(placement: .navigationBarTrailing)"),
            "IOSTerminalNavigationToolbar should own trailing toolbar chrome."
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
