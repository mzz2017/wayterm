import Foundation
import Testing

// Test Context:
// These source-boundary tests protect iOSTerminalView superfile control. The
// iOS terminal root owns top-level composition and intent routing; reusable
// floating controls, navigation toolbar chrome, zen-mode overlay chrome,
// session-page chrome, tab-swipe chrome, presentation sheets, alerts, and
// transient connection chrome should live in sibling UI files so the root view
// does not accumulate presentation subcomponents.
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
        let contentSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/UI/iOS/IOSTerminalContentLayer.swift")
        )
        let sessionPageSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/UI/iOS/IOSTerminalSessionPage.swift")
        )

        // Given iOSTerminalView owns top-level selected-session routing.
        #expect(
            rootSource.contains("IOSTerminalContentLayer("),
            "iOSTerminalView.swift should compose the iOS terminal content layer."
        )

        // Then the per-session terminal/files/progress page composition should
        // live in its own sibling UI component rather than the terminal root.
        #expect(
            !rootSource.contains("IOSTerminalSessionPage("),
            "iOSTerminalView.swift should not directly own the iOS terminal session page."
        )
        #expect(
            !rootSource.contains("private func sessionPage"),
            "iOSTerminalView.swift should not define the session page builder."
        )
        #expect(
            !rootSource.contains("TerminalContainerView("),
            "iOSTerminalView.swift should not directly own terminal container page chrome."
        )
        #expect(
            contentSource.contains("struct IOSTerminalContentLayer: View"),
            "IOSTerminalContentLayer.swift should define the content layer."
        )
        #expect(
            contentSource.contains("IOSTerminalSessionPage("),
            "IOSTerminalContentLayer should own terminal session page composition."
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

    @Test
    func iosTerminalViewComposesTabSwipeOverlayWithoutOwningGestureChrome() throws {
        let root = try sourceRoot()
        let rootSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/UI/iOS/iOSTerminalView.swift")
        )
        let contentSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/UI/iOS/IOSTerminalContentLayer.swift")
        )
        let overlaySource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/UI/iOS/IOSTerminalTabSwipeOverlay.swift")
        )

        // Given iOSTerminalView owns top-level view selection state.
        #expect(
            rootSource.contains("IOSTerminalContentLayer("),
            "iOSTerminalView.swift should compose the content layer that owns tab swipe chrome."
        )

        // Then edge gesture chrome and haptic feedback should live in their own
        // sibling UI component instead of growing the terminal root view.
        #expect(
            !rootSource.contains("IOSTerminalTabSwipeOverlay("),
            "iOSTerminalView.swift should not directly own the tab swipe overlay."
        )
        #expect(
            !rootSource.contains("private var serverViewSwipeOverlay"),
            "iOSTerminalView.swift should not define the tab swipe overlay."
        )
        #expect(
            !rootSource.contains("private func tabSwipeGesture"),
            "iOSTerminalView.swift should not define the tab swipe gesture."
        )
        #expect(
            !rootSource.contains("UIImpactFeedbackGenerator"),
            "iOSTerminalView.swift should not own tab-swipe haptic chrome."
        )
        #expect(
            overlaySource.contains("struct IOSTerminalTabSwipeOverlay: View"),
            "IOSTerminalTabSwipeOverlay.swift should define the swipe overlay component."
        )
        #expect(
            contentSource.contains("IOSTerminalTabSwipeOverlay("),
            "IOSTerminalContentLayer should compose the swipe overlay component."
        )
        #expect(
            overlaySource.contains("DragGesture(minimumDistance: 24"),
            "IOSTerminalTabSwipeOverlay should own the swipe gesture."
        )
        #expect(
            overlaySource.contains("UIImpactFeedbackGenerator"),
            "IOSTerminalTabSwipeOverlay should own tab-swipe haptic feedback."
        )
    }

    @Test
    func iosTerminalViewComposesContentLayerWithoutOwningContentSections() throws {
        let root = try sourceRoot()
        let rootSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/UI/iOS/iOSTerminalView.swift")
        )
        let contentSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/UI/iOS/IOSTerminalContentLayer.swift")
        )

        // Given iOSTerminalView owns top-level state and intent routing.
        #expect(
            rootSource.contains("IOSTerminalContentLayer("),
            "iOSTerminalView.swift should compose the iOS terminal content layer."
        )

        // Then terminal/files/stats content presentation should live in the
        // sibling content layer rather than the root view.
        for helperName in [
            "headerTabsBar",
            "sessionContent",
            "emptyStateContent",
            "activeSessionsContent",
            "backgroundView"
        ] {
            #expect(
                !rootSource.contains("private var \(helperName)"),
                "iOSTerminalView.swift should not own \(helperName) presentation helper."
            )
            #expect(
                contentSource.contains("private var \(helperName)"),
                "IOSTerminalContentLayer.swift should own \(helperName) presentation helper."
            )
        }

        for lifecycleCall in [
            "requestConnectionOpen(",
            "requestForegroundReconnectForSelectedSession(",
            "closeSession(",
            "disconnectServerAndWait",
            "peekTerminal("
        ] {
            #expect(
                rootSource.contains(lifecycleCall),
                "iOSTerminalView.swift should keep lifecycle intent call \(lifecycleCall)."
            )
            #expect(
                !contentSource.contains(lifecycleCall),
                "IOSTerminalContentLayer.swift should not own lifecycle intent call \(lifecycleCall)."
            )
        }
    }

    @Test
    func iosTerminalViewComposesPresentationHostWithoutOwningSheetsAndAlerts() throws {
        let root = try sourceRoot()
        let rootSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/UI/iOS/iOSTerminalView.swift")
        )
        let presentationSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/UI/iOS/IOSTerminalPresentationHost.swift")
        )

        // Given iOSTerminalView owns sheet state and close intent.
        #expect(
            rootSource.contains(".iosTerminalPresentation("),
            "iOSTerminalView.swift should compose the iOS terminal presentation host."
        )
        #expect(
            rootSource.contains("sessionManager.closeSession(session)"),
            "iOSTerminalView.swift should keep close-session intent at the root."
        )

        // Then concrete sheet and alert presentation should live in a sibling
        // modifier without taking over lifecycle intent.
        for helperName in [
            "sheetContent",
            "alertContent"
        ] {
            #expect(
                !rootSource.contains("private var \(helperName)"),
                "iOSTerminalView.swift should not own \(helperName) presentation helper."
            )
        }
        for presentationCall in [
            "SettingsView()",
            "ServerFormSheet(",
            "TmuxAttachPromptSheet(",
            ".limitReachedAlert(",
            ".alert("
        ] {
            #expect(
                !rootSource.contains(presentationCall),
                "iOSTerminalView.swift should not own presentation call \(presentationCall)."
            )
            #expect(
                presentationSource.contains(presentationCall),
                "IOSTerminalPresentationHost.swift should own presentation call \(presentationCall)."
            )
        }
        #expect(
            !presentationSource.contains("ConnectionSessionManager"),
            "IOSTerminalPresentationHost.swift should not depend on TerminalSessions application managers."
        )
    }

    @Test
    func iosTerminalViewUsesPolicyForDerivedDisplayState() throws {
        let root = try sourceRoot()
        let rootSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/UI/iOS/iOSTerminalView.swift")
        )
        let policySource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/IOSTerminalViewPolicy.swift")
        )

        for expression in [
            "currentServerId ?? selectedServer?.id ?? connectingServer?.id",
            "isConnecting || selectedServer != nil || !serverSessions.isEmpty",
            "isZenModeEnabled && canUseZenMode",
            "viewTabConfig.currentVisibleTabs.count > 1"
        ] {
            #expect(
                !rootSource.contains(expression),
                "iOSTerminalView.swift should not own derived iOS terminal display policy."
            )
        }

        for functionName in [
            "fileTabServerId",
            "canUseZenMode",
            "effectiveZenModeEnabled",
            "shouldShowViewSwitcher"
        ] {
            #expect(
                policySource.contains("static func \(functionName)"),
                "IOSTerminalViewPolicy should own \(functionName)."
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
