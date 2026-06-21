import Foundation
import Testing

// Test Context:
// These tests protect Terminal rich-paste image upload ownership. SwiftUI and
// terminal representables may intercept paste, show prompts, and present
// progress or error notices, but upload task lifetime, SSH lease resolution,
// exclusive client use, remote cleanup, and remote-path input must be owned by
// TerminalSessions application managers. The tests inspect source placement
// only; update them only if rich-paste upload ownership intentionally moves to
// another non-UI application owner with equivalent close/cancellation ordering.
@Suite
struct TerminalRichPasteIntentBoundaryTests {
    @Test
    func richPasteSupportDoesNotOwnUploadTasksLeasesOrCoordinator() throws {
        // Given the shared Terminal rich-paste SwiftUI support source.
        let root = try sourceRoot()
        let source = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/UI/Terminal/TerminalRichPasteSupport.swift")
        )

        // Then UI support sends upload intent to managers instead of owning
        // lifecycle-critical upload work or SSH lease teardown.
        #expect(
            source.contains("requestSessionRichPasteUpload("),
            "Root terminal rich-paste upload should route through ConnectionSessionManager."
        )
        #expect(
            source.contains("requestPaneRichPasteUpload("),
            "Split-pane rich-paste upload should route through TerminalTabManager."
        )
        #expect(
            !source.contains("activePasteTask"),
            "TerminalRichPasteSupport must not store upload tasks in UI-owned runtime/controller state."
        )
        #expect(
            !source.contains("TerminalRichPasteCoordinator("),
            "TerminalRichPasteSupport must not instantiate the upload coordinator from UI code."
        )
        #expect(
            !source.contains("performRichPaste("),
            "TerminalRichPasteSupport must not directly run remote upload work."
        )
        #expect(
            !source.contains("resolveRemoteConnectionLease"),
            "TerminalRichPasteSupport must not resolve SSH leases from UI code."
        )
        #expect(
            !source.contains("lease.close()"),
            "TerminalRichPasteSupport must not close SSH leases from UI code."
        )
        #expect(
            !source.contains("withExclusiveClient"),
            "TerminalRichPasteSupport must leave exclusive SSH client use to the application request owner."
        )
    }

    @Test
    func terminalRepresentablesOnlyInstallRichPasteInterception() throws {
        // Given the root and split terminal representable sources.
        let root = try sourceRoot()
        let combinedSource = try [
            "VVTerm/Features/TerminalSessions/UI/Terminal/SSHTerminalWrapper.swift",
            "VVTerm/Features/TerminalSessions/UI/Splits/TerminalView.swift"
        ].map { path in
            try source(at: root.appendingPathComponent(path))
        }.joined(separator: "\n")

        // Then representables may install the paste interceptor, but upload
        // start must still flow through application-layer request APIs.
        #expect(
            combinedSource.contains("richPasteRuntime.install(on:"),
            "Terminal representables should only attach rich-paste UI interception to the terminal surface."
        )
        #expect(
            !combinedSource.contains("TerminalRichPasteCoordinator("),
            "Terminal representables must not instantiate the upload coordinator."
        )
        #expect(
            !combinedSource.contains("remoteConnectionLease(for"),
            "Terminal representables must not resolve SSH leases for rich-paste upload."
        )
    }

    @Test
    func applicationLayerOwnsExclusiveLeaseUseAndRemotePathInput() throws {
        // Given the TerminalSessions application rich-paste request owner.
        let root = try sourceRoot()
        let source = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/Application/TerminalRichPasteUploadRequest.swift")
        )

        // Then application code owns the exclusive lease operation, awaited
        // lease close, and shell-escaped remote path input payload.
        #expect(source.contains("withExclusiveClient"))
        #expect(source.contains("await lease.close()"))
        #expect(source.contains("RemoteTerminalBootstrap.posixPastedPath"))
    }

    @Test
    func remoteClipboardTransferDoesNotStartUntrackedStaleSweepTask() throws {
        // Given the Core SSH remote clipboard transfer service.
        let root = try sourceRoot()
        let source = try source(
            at: root.appendingPathComponent("VVTerm/Core/SSH/RemoteClipboardTransferService.swift")
        )

        // Then stale cleanup must not use a detached delayed task that can
        // outlive the lease whose client it captured.
        #expect(
            !containsRegex(#"Task\s*\(\s*priority:\s*\.utility\s*\)"#, in: source),
            "Remote clipboard cleanup must be awaited or returned to the rich-paste request owner instead of firing an untracked task."
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

    private func containsRegex(_ pattern: String, in source: String) -> Bool {
        source.range(of: pattern, options: .regularExpression) != nil
    }

    private enum SourceRootError: Error {
        case notFound
    }
}
