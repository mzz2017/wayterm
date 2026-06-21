import Foundation
import Testing

// Test Context:
// These tests protect Settings UI/Application boundaries for lifecycle-critical
// persistence and cleanup actions. Settings views may send user intent, but they
// must not own destructive cleanup tasks or call lower-level stores directly.
// The tests inspect source placement only; update them only when the trusted
// host settings owner intentionally moves to a different application-layer type.
@Suite
struct SettingsLifecycleBoundaryTests {
    @Test
    func terminalSettingsDelegatesTrustedHostCleanupToApplicationStore() throws {
        // Given the terminal settings SwiftUI source.
        let root = try sourceRoot()
        let source = try source(
            at: root.appendingPathComponent("VVTerm/Features/Settings/UI/TerminalSettingsView.swift")
        )

        // Then the view must observe an application-layer settings store rather
        // than owning the reset task or directly touching KnownHostsStore.
        #expect(
            !source.contains("KnownHostsStore.shared"),
            "TerminalSettingsView should call TrustedHostsSettingsStore instead of KnownHostsStore.shared."
        )
        #expect(
            !source.contains("knownHostsTask"),
            "TerminalSettingsView should not own trusted-host refresh/reset Task state."
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
