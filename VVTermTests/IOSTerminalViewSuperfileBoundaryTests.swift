import Foundation
import Testing

// Test Context:
// These source-boundary tests protect iOSTerminalView superfile control. The
// iOS terminal root owns top-level composition and intent routing; reusable
// floating controls, navigation toolbar chrome, zen-mode overlay chrome,
// session-page chrome, and transient connection chrome should live in sibling
// UI files so the root view does not accumulate presentation subcomponents.
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

    @Test
    func iosTerminalViewComposesZenOverlayWithoutOwningOverlayChrome() throws {
        let root = try sourceRoot()
        let rootSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/UI/iOS/iOSTerminalView.swift")
        )
        let overlaySource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/UI/iOS/IOSTerminalZenModeOverlay.swift")
        )

        // Given iOSTerminalView owns zen-mode state and intent routing.
        #expect(
            rootSource.contains("IOSTerminalZenModeOverlay("),
            "iOSTerminalView.swift should compose the iOS terminal zen overlay."
        )

        // Then reusable overlay presentation should live in its own sibling UI
        // component rather than growing the terminal root view.
        #expect(
            !rootSource.contains("ZenModeFloatingOverlay("),
            "iOSTerminalView.swift should not directly own zen floating overlay chrome."
        )
        #expect(
            !rootSource.contains("IOSZenModePanel("),
            "iOSTerminalView.swift should not directly own the iOS zen panel."
        )
        #expect(
            overlaySource.contains("struct IOSTerminalZenModeOverlay: View"),
            "IOSTerminalZenModeOverlay.swift should define the overlay component."
        )
        #expect(
            overlaySource.contains("ZenModeFloatingOverlay("),
            "IOSTerminalZenModeOverlay should own the floating overlay chrome."
        )
        #expect(
            overlaySource.contains("IOSZenModePanel("),
            "IOSTerminalZenModeOverlay should own the iOS zen panel composition."
        )
    }

    @Test
    func iosTerminalViewComposesSessionPageWithoutOwningSessionPageChrome() throws {
        let root = try sourceRoot()
        let rootSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/UI/iOS/iOSTerminalView.swift")
        )
        let sessionPageSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/UI/iOS/IOSTerminalSessionPage.swift")
        )

        // Given iOSTerminalView owns top-level selected-session routing.
        #expect(
            rootSource.contains("IOSTerminalSessionPage("),
            "iOSTerminalView.swift should compose the iOS terminal session page."
        )

        // Then the per-session terminal/files/progress page composition should
        // live in its own sibling UI component rather than the terminal root.
        #expect(
            !rootSource.contains("private func sessionPage"),
            "iOSTerminalView.swift should not define the session page builder."
        )
        #expect(
            !rootSource.contains("TerminalContainerView("),
            "iOSTerminalView.swift should not directly own terminal container page chrome."
        )
        #expect(
            sessionPageSource.contains("struct IOSTerminalSessionPage: View"),
            "IOSTerminalSessionPage.swift should define the session page component."
        )
        #expect(
            sessionPageSource.contains("TerminalContainerView("),
            "IOSTerminalSessionPage should own terminal container page composition."
        )
        #expect(
            sessionPageSource.contains("IOSTerminalViewPolicy.terminalPreparation"),
            "IOSTerminalSessionPage should preserve terminal preparation policy use."
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
