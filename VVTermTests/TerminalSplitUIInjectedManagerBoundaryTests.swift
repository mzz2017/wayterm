import Foundation
import Testing

// Test Context:
// Protected behavior: split terminal UI may send user intent, but it must send
// that intent through injected application owners and entitlement dependencies.
// Target invariant: TerminalTabView and TerminalPaneView must use their
// injected managers; they must not resolve shared singletons.
// Fake assumptions: these are source-boundary tests because the protected
// behavior is dependency ownership at the SwiftUI/application boundary.
// Update guidance: update these tests only if split terminal UI ownership
// intentionally moves to a different injected application owner.
@Suite(.serialized)
struct TerminalSplitUIInjectedManagerBoundaryTests {
    @Test
    func terminalTabViewUsesInjectedManagerForFocusedTerminalLookup() throws {
        let root = try sourceRoot()
        let source = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/UI/Splits/TerminalView.swift")
        )
        let tabView = try slice(
            startingAt: "struct TerminalTabView",
            endingBefore: "#endif",
            in: source
        )

        // Given the split tab view receives the application owner from its parent boundary.
        #expect(
            tabView.contains("@ObservedObject var tabManager: TerminalTabManager"),
            "TerminalTabView should receive the injected tab manager."
        )

        // When it derives focused-terminal presentation state.
        #expect(
            tabView.contains("tabManager.getTerminal(for: tab.focusedPaneId)"),
            "Focused terminal lookup should use the injected tab manager."
        )

        // Then split tab UI must not bypass injection through the singleton.
        #expect(!tabView.contains("TerminalTabManager.shared"))
    }

    @Test
    func terminalPaneViewUsesInjectedManagerForPaneLifecycleIntents() throws {
        let root = try sourceRoot()
        let source = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/UI/Splits/TerminalPaneView.swift")
        )
        let paneView = try slice(
            startingAt: "struct TerminalPaneView",
            endingBefore: "private func updateTerminalBackgroundColor",
            in: source
        )

        // Given the pane view already receives the same application owner.
        #expect(
            paneView.contains("let tabManager: TerminalTabManager"),
            "TerminalPaneView should receive the injected tab manager."
        )

        // When user prompts and lifecycle callbacks send pane intents.
        for expectedCall in [
            "tabManager.requestTmuxInstall",
            "tabManager.disableTmux",
            "tabManager.requestPaneHostRetrust",
            "tabManager.shouldAutoReconnectPane",
            "tabManager.requestPaneRetry",
            "tabManager.requestPaneCredentialLoad",
            "tabManager.paneStates",
            "tabManager.scheduleConnectWatchdog",
            "tabManager.requestMoshInstallAndReconnect"
        ] {
            #expect(
                paneView.contains(expectedCall),
                "Split pane UI lifecycle intent should use injected manager call \(expectedCall)."
            )
        }

        // Then pane UI must not bypass injection through the singleton.
        #expect(!paneView.contains("TerminalTabManager.shared"))
    }

    @Test
    func splitTerminalViewHasNoTerminalTabManagerSingletonReachThrough() throws {
        let root = try sourceRoot()
        let terminalViewSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/UI/Splits/TerminalView.swift")
        )
        let paneSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/UI/Splits/TerminalPaneView.swift")
        )

        // Then split terminal UI files should not resolve the tab manager singleton.
        #expect(!terminalViewSource.contains("TerminalTabManager.shared"))
        #expect(!paneSource.contains("TerminalTabManager.shared"))
    }

    @Test
    func terminalTabViewUsesInjectedStoreManagerForSplitEntitlement() throws {
        let root = try sourceRoot()
        let terminalViewSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/UI/Splits/TerminalView.swift")
        )
        let tabsSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/UI/Tabs/ConnectionTabsView.swift")
        )
        let tabView = try slice(
            startingAt: "struct TerminalTabView",
            endingBefore: "#endif",
            in: terminalViewSource
        )

        // Given split-pane creation is a Pro entitlement boundary.
        #expect(
            tabView.contains("@ObservedObject var storeManager: StoreManager"),
            "TerminalTabView should receive StoreManager from its server terminal composition boundary."
        )
        #expect(
            tabView.contains("guard storeManager.isPro else"),
            "Split-pane entitlement checks should use the injected StoreManager."
        )
        #expect(
            !tabView.contains("StoreManager.shared"),
            "TerminalTabView should not resolve StoreManager.shared from split UI."
        )
        #expect(
            tabsSource.contains("storeManager: storeManager"),
            "ConnectionTabsView should pass its injected StoreManager into TerminalTabView."
        )
    }

    private func slice(startingAt marker: String, endingBefore endMarker: String, in source: String) throws -> String {
        guard let start = source.range(of: marker),
              let end = source.range(of: endMarker, range: start.lowerBound..<source.endIndex)
        else {
            throw SourceSliceError.notFound
        }
        return String(source[start.lowerBound..<end.lowerBound])
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

    private enum SourceSliceError: Error {
        case notFound
    }
}
