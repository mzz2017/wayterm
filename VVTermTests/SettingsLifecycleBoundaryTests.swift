import Foundation
import Testing

// Test Context:
// These tests protect Settings UI/Application boundaries for lifecycle-critical
// persistence and cleanup actions. Settings views may send user intent, but they
// must not own destructive cleanup tasks or call lower-level stores directly.
// The tests inspect source placement only; update them only when the trusted
// host, reusable SSH key, sync settings, or custom terminal theme settings owner
// intentionally moves to another application-layer type.
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

    @Test
    func keychainSettingsDelegatesSSHKeyLibraryLifecycleToApplicationStore() throws {
        // Given the SSH key settings SwiftUI source.
        let root = try sourceRoot()
        let source = try source(
            at: root.appendingPathComponent("VVTerm/Features/Settings/UI/KeychainSettingsView.swift")
        )

        // Then the view must send intent to a Settings application store rather
        // than directly touching Keychain, generating keys, or owning key tasks.
        #expect(
            !source.contains("KeychainManager.shared"),
            "KeychainSettingsView should call SSHKeySettingsStore instead of KeychainManager.shared."
        )
        #expect(
            !source.contains("SSHKeyGenerator.generate"),
            "KeychainSettingsView should delegate SSH key generation to the application store."
        )
        #expect(
            !source.contains("Task {"),
            "KeychainSettingsView should not own SSH key generation Task state."
        )
    }

    @Test
    func terminalSettingsDoesNotSwallowCustomThemePersistenceFailures() throws {
        // Given the terminal settings SwiftUI source and its custom theme
        // management child views.
        let root = try sourceRoot()
        let terminalSettingsSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/Settings/UI/TerminalSettingsView.swift")
        )
        let customThemeManagementSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/Settings/UI/TerminalCustomThemeManagementViews.swift")
        )
        let combinedSource = terminalSettingsSource + "\n" + customThemeManagementSource

        // Then custom theme deletion must keep using the throwing
        // TerminalThemeManager intent so persistence failure can be surfaced to
        // the sheet instead of being swallowed by UI code.
        #expect(
            !combinedSource.contains("try? terminalThemeManager.deleteCustomTheme"),
            "TerminalSettingsView should not swallow custom theme delete failures with try?."
        )
        #expect(
            customThemeManagementSource.contains("let onDelete: (UUID) throws -> Void"),
            "ManageCustomThemesSheet should keep custom theme deletion as a throwing intent."
        )
    }

    @Test
    func syncSettingsDelegatesCloudKitStatusAndIntentToApplicationStore() throws {
        // Given the sync settings SwiftUI source.
        let root = try sourceRoot()
        let source = try source(
            at: root.appendingPathComponent("VVTerm/Features/Settings/UI/SyncSettingsView.swift")
        )

        // Then the view must observe the Settings application store rather than
        // directly owning CloudKit status observation or app-sync coordination.
        #expect(
            !source.contains("CloudKitManager.shared"),
            "SyncSettingsView should read CloudKit status through SyncSettingsStore instead of CloudKitManager.shared."
        )
        #expect(
            !source.contains("AppSyncCoordinator.shared"),
            "SyncSettingsView should send sync intent through SyncSettingsStore instead of AppSyncCoordinator.shared."
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
