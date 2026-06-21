import Foundation
import Testing

// Test Context:
// These source-boundary tests protect split-pane terminal surface callback
// ownership. SwiftUI/AppKit representables may receive Ghostty surface events,
// but those callbacks must report intent through the injected TerminalSessions
// application manager instead of reaching for the TerminalTabManager singleton.
// Static teardown in dismantleNSView is intentionally excluded here because it
// has no instance injection point; update these tests only if split pane surface
// callback ownership intentionally moves to a different injected application
// owner or static teardown is redesigned in a later lifetime task.
@Suite(.serialized)
struct TerminalSplitSurfaceCallbackBoundaryTests {
    @Test
    func splitPaneWrapperUsesInjectedManagerForSurfaceCallbacks() throws {
        let root = try sourceRoot()
        let source = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/UI/Splits/TerminalView.swift")
        )
        let wrapper = try slice(
            startingAt: "struct SSHTerminalPaneWrapper",
            endingBefore: "static func dismantleNSView",
            in: source
        )

        // Given the split pane terminal representable receives Ghostty surface callbacks.
        #expect(
            wrapper.contains("let tabManager: TerminalTabManager"),
            "SSHTerminalPaneWrapper should receive its application manager from TerminalPaneView."
        )

        // When callbacks report pane runtime and metadata events.
        for expectedCall in [
            "tabManager.configureRuntime",
            "tabManager.getTerminal",
            "tabManager.updatePaneWorkingDirectory",
            "tabManager.updatePaneTitle",
            "tabManager.handleTerminalZoom",
            "tabManager.presentationOverrides",
            "tabManager.registerTerminal",
            "tabManager.requestPaneResize",
            "tabManager.requestPaneInput"
        ] {
            #expect(
                wrapper.contains(expectedCall),
                "Split pane surface callbacks should use injected manager call \(expectedCall)."
            )
        }

        // Then instance callbacks must not bypass injection through the singleton.
        #expect(!wrapper.contains("TerminalTabManager.shared"))
    }

    @Test
    func splitPaneCoordinatorUsesInjectedManagerForRuntimeCallbacks() throws {
        let root = try sourceRoot()
        let source = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/UI/Splits/TerminalView.swift")
        )
        let coordinator = try slice(
            startingAt: "func makeCoordinator()",
            endingBefore: "#endif",
            in: source
        )

        // Given the split pane coordinator handles input, attach, and cleanup callbacks.
        #expect(
            coordinator.contains("tabManager: tabManager"),
            "makeCoordinator should pass the injected manager into the coordinator."
        )
        #expect(
            coordinator.contains("let tabManager: TerminalTabManager"),
            "Coordinator should retain the injected manager for callback routing."
        )

        // When coordinator callbacks run outside SwiftUI body evaluation.
        for expectedCall in [
            "tabManager.requestPaneInput",
            "tabManager.requestSurfaceAttach",
            "tabManager.detachSurfaceForClosedPane"
        ] {
            #expect(
                coordinator.contains(expectedCall),
                "Split pane coordinator should use injected manager call \(expectedCall)."
            )
        }

        // Then coordinator callbacks must not bypass injection through the singleton.
        #expect(!coordinator.contains("TerminalTabManager.shared"))
    }

    @Test
    func terminalPaneViewInjectsTabManagerIntoWrapper() throws {
        let root = try sourceRoot()
        let source = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/UI/Splits/TerminalView.swift")
        )
        let paneView = try slice(
            startingAt: "struct TerminalPaneView",
            endingBefore: "struct SSHTerminalPaneWrapper",
            in: source
        )

        // Given TerminalPaneView constructs the split pane terminal wrapper.
        #expect(
            paneView.contains("let tabManager: TerminalTabManager"),
            "TerminalPaneView should receive the same tab manager as TerminalTabView."
        )

        // Then the wrapper should receive that manager instead of resolving a singleton.
        #expect(
            paneView.contains("tabManager: tabManager"),
            "TerminalPaneView should inject tabManager into SSHTerminalPaneWrapper."
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
