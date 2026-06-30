import Foundation
import Testing

// Test Context:
// These source-boundary tests protect terminal install intent ownership. The
// production contract is that SwiftUI terminal views may present install
// prompts and send synchronous intent, while TerminalSessions Application
// managers own tmux/mosh install and reconnect task lifecycles. Update these
// tests only when install lifecycle ownership intentionally moves to another
// non-UI application owner; do not update them for cosmetic UI rewrites.

@Suite(.serialized)
struct TerminalInstallIntentBoundaryTests {
    @Test
    func terminalContainerInstallAlertsSendIntentWithoutOwningInstallTasks() throws {
        let root = try sourceRoot()
        let source = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/UI/Terminal/TerminalContainerView.swift")
        )
        let installAlerts = try slice(
            startingAt: ".alert(\"Install tmux?\"",
            endingBefore: ".alert(\"Trust SSH Host Key?\"",
            in: source
        )
        let moshRequestHelper = try slice(
            startingAt: "private func requestMoshInstallAndReconnect()",
            endingBefore: "private func requestCredentialLoadIfNeeded",
            in: source
        )

        // Given the single-session terminal SwiftUI install prompt source.
        #expect(
            installAlerts.contains("sessionManager.requestTmuxInstall"),
            "The tmux install button should send request intent to the injected session manager."
        )
        #expect(
            installAlerts.contains("requestMoshInstallAndReconnect()"),
            "The mosh install button should call the presentation helper synchronously."
        )
        #expect(
            moshRequestHelper.contains("sessionManager.requestMoshInstallAndReconnect"),
            "The mosh helper should send request intent to the injected session manager."
        )

        // Then SwiftUI must not own the install task or call the old async
        // helper directly.
        #expect(!installAlerts.contains("Task {"))
        #expect(!moshRequestHelper.contains("try await"))
        #expect(!installAlerts.contains("ConnectionSessionManager.shared.requestTmuxInstall"))
        #expect(!moshRequestHelper.contains("ConnectionSessionManager.shared.requestMoshInstallAndReconnect"))
        #expect(!installAlerts.contains("await ConnectionSessionManager.shared.startTmuxInstall"))
        #expect(!installAlerts.contains("await installMoshServerAndReconnect()"))
        #expect(!moshRequestHelper.contains("ConnectionSessionManager.shared.installMoshServerAndReconnect"))
    }

    @Test
    func splitTerminalInstallAlertsSendIntentWithoutOwningInstallTasks() throws {
        let root = try sourceRoot()
        let source = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/UI/Splits/TerminalPaneView.swift")
        )
        let installAlerts = try slice(
            startingAt: ".alert(\"Install tmux?\"",
            endingBefore: ".alert(\"Trust SSH Host Key?\"",
            in: source
        )
        let moshRequestHelper = try slice(
            startingAt: "private func requestMoshInstallAndReconnect()",
            endingBefore: "private func updateTerminalBackgroundColor",
            in: source
        )

        // Given the split terminal SwiftUI install prompt source.
        #expect(
            installAlerts.contains("tabManager.requestTmuxInstall"),
            "The tmux install button should send request intent to the injected tab manager."
        )
        #expect(
            installAlerts.contains("requestMoshInstallAndReconnect()"),
            "The mosh install button should call the presentation helper synchronously."
        )
        #expect(
            moshRequestHelper.contains("tabManager.requestMoshInstallAndReconnect"),
            "The mosh helper should send request intent to the injected tab manager."
        )

        // Then SwiftUI must not own the install task or call the old async
        // helper directly.
        #expect(!installAlerts.contains("Task {"))
        #expect(!moshRequestHelper.contains("try await"))
        #expect(!installAlerts.contains("await TerminalTabManager.shared.startTmuxInstall"))
        #expect(!installAlerts.contains("await installMoshServerAndReconnect()"))
        #expect(!moshRequestHelper.contains("TerminalTabManager.shared.installMoshServerAndReconnect"))
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
        while url.pathComponents.count > 1 {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("VVTerm.xcodeproj").path) {
                return url
            }
            url.deleteLastPathComponent()
        }
        throw SourceRootError.notFound
    }

    private enum SourceRootError: Error {
        case notFound
    }

    private enum SourceSliceError: Error {
        case notFound
    }
}
