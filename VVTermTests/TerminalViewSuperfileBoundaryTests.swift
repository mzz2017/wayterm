import Foundation
import Testing

// Test Context:
// These source-boundary tests protect split terminal superfile control.
// TerminalView owns tab-level split tree composition and pane selection intent;
// TerminalPaneView owns a single pane's connection presentation and pane-scoped
// lifecycle intent. Update these tests only when that ownership boundary
// intentionally changes, not for cosmetic UI movement.
@Suite(.serialized)
struct TerminalViewSuperfileBoundaryTests {
    @Test
    func terminalViewComposesPaneViewWithoutDefiningPaneLifecycleUI() throws {
        let root = try sourceRoot()
        let terminalViewSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/UI/Splits/TerminalView.swift")
        )
        let paneViewSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/UI/Splits/TerminalPaneView.swift")
        )

        // Given TerminalView owns split tree composition.
        #expect(
            terminalViewSource.contains("TerminalPaneView("),
            "TerminalView.swift should compose TerminalPaneView leaves."
        )

        // Then the pane UI and pane-scoped lifecycle intent should live in the
        // sibling pane view file instead of inflating the split-tree root.
        #expect(
            !terminalViewSource.contains("struct TerminalPaneView: View"),
            "TerminalView.swift should not define TerminalPaneView."
        )
        #expect(
            paneViewSource.contains("struct TerminalPaneView: View"),
            "TerminalPaneView.swift should define TerminalPaneView."
        )

        // Split panes share terminal presentation rules with the single-session
        // container instead of duplicating mosh, reconnect, and host-key policy.
        for presentationPolicyCall in [
            "TerminalContainerPresentationPolicy.fallbackBannerMessage",
            "TerminalContainerPresentationPolicy.shouldPromptMoshInstall",
            "TerminalContainerPresentationPolicy.shouldShowMoshDurabilityHint",
            "TerminalContainerPresentationPolicy.shouldUseInlineReconnectPresentation",
            "TerminalContainerPresentationPolicy.reconnectBannerMessage",
            "TerminalContainerPresentationPolicy.isHostKeyVerificationFailure"
        ] {
            #expect(
                paneViewSource.contains(presentationPolicyCall),
                "TerminalPaneView.swift should delegate split-pane presentation rule \(presentationPolicyCall)."
            )
        }

        for duplicatedRule in [
            "return paneState?.moshFallbackReason == .serverMissing",
            "return paneState?.tmuxStatus == .off",
            "hasEstablishedConnection && terminalExists && connectionState.isConnecting",
            "error.contains(\"Host key verification failed\")"
        ] {
            #expect(
                !paneViewSource.contains(duplicatedRule),
                "TerminalPaneView.swift should not duplicate TerminalContainerPresentationPolicy rule \(duplicatedRule)."
            )
        }

        for paneIntent in [
            "requestPaneRetry(",
            "requestPaneCredentialLoad(",
            "requestPaneHostRetrust(",
            "requestMoshInstallAndReconnect(",
            "scheduleConnectWatchdog("
        ] {
            #expect(
                !terminalViewSource.contains(paneIntent),
                "TerminalView.swift should not own pane lifecycle intent \(paneIntent)."
            )
            #expect(
                paneViewSource.contains(paneIntent),
                "TerminalPaneView.swift should own pane lifecycle intent \(paneIntent)."
            )
        }

        // Split-tree intent remains in TerminalView because it owns pane
        // selection and split layout mutation.
        #expect(
            terminalViewSource.contains("requestPaneProcessExit("),
            "TerminalView.swift should keep split-tree process-exit routing."
        )
        #expect(
            terminalViewSource.contains("splitHorizontal("),
            "TerminalView.swift should keep split-tree split commands."
        )
        #expect(
            terminalViewSource.contains("splitVertical("),
            "TerminalView.swift should keep split-tree split commands."
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
