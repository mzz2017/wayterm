import Foundation
import Testing

// Test Context:
// These source-boundary tests protect TerminalContainerView superfile control.
// The container owns terminal lifecycle intent routing through application-layer
// managers; reusable connection overlays, voice overlay chrome, and empty-state
// presentation should live in sibling UI files. Update this test only when the
// TerminalSessions terminal container ownership boundary intentionally changes.
@Suite
struct TerminalContainerSuperfileBoundaryTests {
    @Test
    func terminalContainerComposesOverlayViewsWithoutOwningTheirLayout() throws {
        let root = try sourceRoot()
        let containerSource = try source(
            at: root.appendingPathComponent("Waterm/Features/TerminalSessions/UI/Terminal/TerminalContainerView.swift")
        )
        let overlaySource = try source(
            at: root.appendingPathComponent("Waterm/Features/TerminalSessions/UI/Terminal/TerminalContainerOverlayViews.swift")
        )

        for component in [
            "TerminalContainerStateOverlay",
            "TerminalContainerVoiceOverlayLayer"
        ] {
            #expect(
                containerSource.contains("\(component)("),
                "TerminalContainerView.swift should compose \(component)."
            )
            #expect(
                !containerSource.contains("struct \(component)"),
                "TerminalContainerView.swift should not define \(component)."
            )
            #expect(
                overlaySource.contains("struct \(component)"),
                "TerminalContainerOverlayViews.swift should define \(component)."
            )
        }

        #expect(
            !containerSource.contains("struct TerminalEmptyStateView"),
            "TerminalContainerView.swift should not define shared empty-state presentation."
        )
        #expect(
            overlaySource.contains("struct TerminalEmptyStateView"),
            "TerminalContainerOverlayViews.swift should own shared terminal empty-state presentation."
        )
        #expect(
            !containerSource.contains("private var stateOverlayLayer"),
            "TerminalContainerView.swift should not own state overlay layout helpers."
        )
        #expect(
            !containerSource.contains("private var voiceOverlayLayer"),
            "TerminalContainerView.swift should not own voice overlay layout helpers."
        )
    }

    @Test
    func terminalOverlayViewsDoNotOwnTerminalLifecycleIntent() throws {
        let root = try sourceRoot()
        let containerSource = try source(
            at: root.appendingPathComponent("Waterm/Features/TerminalSessions/UI/Terminal/TerminalContainerView.swift")
        )
        let overlaySource = try source(
            at: root.appendingPathComponent("Waterm/Features/TerminalSessions/UI/Terminal/TerminalContainerOverlayViews.swift")
        )

        // Given TerminalContainerView owns terminal lifecycle intent routing.
        for expectedCall in [
            "requestSessionRetry(",
            "requestSessionHostRetrust(",
            "requestSessionCredentialLoad(",
            "requestMoshInstallAndReconnect(",
            "scheduleConnectWatchdog("
        ] {
            #expect(
                containerSource.contains(expectedCall),
                "TerminalContainerView.swift should keep lifecycle intent call \(expectedCall)."
            )
            #expect(
                !overlaySource.contains(expectedCall),
                "TerminalContainerOverlayViews.swift should not own lifecycle intent call \(expectedCall)."
            )
        }

        #expect(
            !overlaySource.contains("ConnectionSessionManager"),
            "TerminalContainerOverlayViews.swift should not depend on TerminalSessions application managers."
        )
        #expect(
            !overlaySource.contains("SSHTerminalWrapper("),
            "TerminalContainerOverlayViews.swift should not own terminal surface construction."
        )
        #expect(
            overlaySource.contains("let onRetry: () -> Void"),
            "TerminalContainerOverlayViews.swift should receive retry intent as a closure."
        )
    }

    private func source(at url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    private func sourceRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.lastPathComponent != "WatermTests" {
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
