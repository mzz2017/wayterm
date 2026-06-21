import Foundation
import Testing

// Test Context:
// Protected behavior: split terminal UI may send user intent, but it must send
// that intent through the injected TerminalSessions application owner.
// Target invariant: TerminalTabView and TerminalPaneView must use their
// injected tabManager; they must not resolve TerminalTabManager.shared.
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
            endingBefore: "// MARK: - Terminal Pane View",
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
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/UI/Splits/TerminalView.swift")
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
        let source = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/UI/Splits/TerminalView.swift")
        )

        // Then the split terminal UI file should not resolve the tab manager singleton.
        #expect(!source.contains("TerminalTabManager.shared"))
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
