import Foundation
import Testing

// Test Context:
// These source-boundary tests protect terminal credential-load ownership. Root
// and split SwiftUI views may keep presentation state and send synchronous
// credential-load intent, but TerminalSessions Application managers must own
// Keychain-backed credential-load task lifecycles. Update these tests only when
// credential-load ownership intentionally moves to another non-UI application
// owner.

@Suite(.serialized)
struct TerminalCredentialLoadIntentBoundaryTests {
    @Test
    func terminalContainerSendsCredentialLoadIntentWithoutOwningTasks() throws {
        let root = try sourceRoot()
        let source = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/UI/Terminal/TerminalContainerView.swift")
        )

        // Given the root terminal SwiftUI source needs credentials before
        // rendering the SSH terminal wrapper.
        #expect(
            source.contains("ConnectionSessionManager.shared.requestSessionCredentialLoad"),
            "Root terminal UI should send credential-load intent to ConnectionSessionManager."
        )

        // Then SwiftUI should not own a credential-load task or directly await
        // the low-level application helper.
        #expect(
            !source.containsRegex(#"Task\s*\{\s*await\s+loadCredentialsIfNeeded"#),
            "Root terminal UI should not wrap credential loading in a SwiftUI-owned Task."
        )
        #expect(
            !source.contains("await ConnectionSessionManager.shared.loadCredentials"),
            "Root terminal UI should not call the low-level credential-load helper directly."
        )
        #expect(
            !source.contains("private func loadCredentialsIfNeeded(force: Bool) async"),
            "The root credential-load helper should be synchronous intent, not async work owned by SwiftUI."
        )
    }

    @Test
    func splitTerminalSendsCredentialLoadIntentWithoutOwningTasks() throws {
        let root = try sourceRoot()
        let source = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/UI/Splits/TerminalView.swift")
        )

        // Given the split terminal SwiftUI source needs credentials before
        // rendering the SSH pane wrapper.
        #expect(
            source.contains("tabManager.requestPaneCredentialLoad"),
            "Split terminal UI should send credential-load intent to TerminalTabManager."
        )

        // Then SwiftUI should not directly await the low-level application
        // credential helper from its view task.
        #expect(
            !source.contains("await tabManager.loadCredentials"),
            "Split terminal UI should not call the low-level credential-load helper directly."
        )
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
}

private extension String {
    func containsRegex(_ pattern: String) -> Bool {
        range(of: pattern, options: .regularExpression) != nil
    }
}
