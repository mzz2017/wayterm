import Foundation
import Testing

// Test Context:
// These tests protect Settings UI/Application boundaries for lifecycle-critical
// persistence, purchase, sync, SSH key storage, trusted-host cleanup, and
// tab-configuration actions. Settings views may send user intent, but they must
// not own destructive cleanup tasks or call lower-level stores directly.
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

    @Test
    func proAndSyncSettingsReceiveBusinessStoresFromSettingsRoot() throws {
        // Given the Pro, Sync, and Settings root SwiftUI source.
        let root = try sourceRoot()
        let proSettingsSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/Settings/UI/ProSettingsView.swift")
        )
        let syncSettingsSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/Settings/UI/SyncSettingsView.swift")
        )
        let settingsSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/Settings/UI/SettingsView.swift")
        )

        // Then leaf settings views must render injected application stores, while
        // live singleton wiring stays outside the Settings UI source file.
        #expect(
            !proSettingsSource.contains("StoreManager.shared"),
            "ProSettingsView should receive StoreManager from SettingsView instead of resolving StoreManager.shared."
        )
        #expect(
            !proSettingsSource.contains("ServerManager.shared"),
            "ProSettingsView should receive ServerManager from SettingsView instead of resolving ServerManager.shared."
        )
        #expect(
            !syncSettingsSource.contains("SyncSettingsStore.shared"),
            "SyncSettingsView should receive SyncSettingsStore from SettingsView instead of resolving SyncSettingsStore.shared."
        )
        #expect(
            !syncSettingsSource.contains("ServerManager.shared"),
            "SyncSettingsView should receive ServerManager from SettingsView instead of resolving ServerManager.shared."
        )
        #expect(
            !settingsSource.contains(".shared"),
            "SettingsView should receive live stores through SettingsViewDependencies, with .shared wiring kept outside the Settings UI file."
        )
        #expect(
            settingsSource.contains("init(dependencies: SettingsViewDependencies)"),
            "SettingsView should expose an explicit dependency initializer."
        )
    }

    @Test
    func generalTerminalAndKeychainSettingsReceiveBusinessStoresFromSettingsRoot() throws {
        // Given the General, Terminal, Keychain, and Settings root SwiftUI source.
        let root = try sourceRoot()
        let generalSettingsSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/Settings/UI/GeneralSettingsView.swift")
        )
        let terminalSettingsSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/Settings/UI/TerminalSettingsView.swift")
        )
        let keychainSettingsSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/Settings/UI/KeychainSettingsView.swift")
        )
        let settingsSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/Settings/UI/SettingsView.swift")
        )

        // Then these leaf views must receive application stores from SettingsView
        // rather than resolving business singletons by themselves.
        #expect(
            !generalSettingsSource.contains("ViewTabConfigurationManager.shared"),
            "GeneralSettingsView should receive ViewTabConfigurationManager from SettingsView."
        )
        #expect(
            !terminalSettingsSource.contains("TrustedHostsSettingsStore.shared"),
            "TerminalSettingsView should receive TrustedHostsSettingsStore from SettingsView."
        )
        #expect(
            !keychainSettingsSource.contains("SSHKeySettingsStore.shared"),
            "KeychainSettingsView should receive SSHKeySettingsStore from SettingsView."
        )
        #expect(
            settingsSource.contains("GeneralSettingsView(viewTabConfig: viewTabConfig)"),
            "SettingsView should inject ViewTabConfigurationManager into GeneralSettingsView."
        )
        #expect(
            settingsSource.contains("trustedHostsStore: trustedHostsStore"),
            "SettingsView should inject TrustedHostsSettingsStore into TerminalSettingsView."
        )
        #expect(
            settingsSource.contains("KeychainSettingsView(keyStore: keyStore)"),
            "SettingsView should inject SSHKeySettingsStore into KeychainSettingsView."
        )
    }

    @Test
    func transcriptionSettingsReceivesModelDownloadStoreFromSettingsRoot() throws {
        // Given the transcription settings leaf view and Settings root source.
        let root = try sourceRoot()
        let transcriptionSettingsSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/VoiceInput/UI/Settings/TranscriptionSettingsView.swift")
        )
        let settingsSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/Settings/UI/SettingsView.swift")
        )

        // Then the leaf view should render injected model-download state rather
        // than resolving the live application store by itself.
        #expect(
            !transcriptionSettingsSource.contains("self.init(modelDownloads: .shared)"),
            "TranscriptionSettingsView should not resolve VoiceModelDownloadStore.shared from leaf UI."
        )
        #expect(
            settingsSource.contains("TranscriptionSettingsView(modelDownloads: voiceModelDownloads)"),
            "SettingsView should pass the model download store into the transcription settings screen."
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
