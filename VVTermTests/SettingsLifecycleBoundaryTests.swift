import Foundation
import Testing

// Test Context:
// These tests protect Settings UI/Application boundaries for lifecycle-critical
// persistence, purchase/review mode, sync, SSH key storage, trusted-host cleanup,
// tab-configuration actions, symbol-picker persistence/system catalog loading,
// and model-download lifecycle. Settings views may send user intent, but they
// must not own destructive cleanup tasks or call lower-level stores directly.
// The tests inspect source placement only; update them only when the trusted
// host, reusable SSH key, sync settings, purchase/review mode, transcription
// download, SF Symbol picker services, or custom terminal theme settings owner
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
        let viewSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/Settings/UI/SyncSettingsView.swift")
        )
        let storeSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/Settings/Application/SyncSettingsStore.swift")
        )

        // Then the view must observe the Settings application store rather than
        // directly owning CloudKit status observation or app-sync coordination.
        #expect(
            !viewSource.contains("CloudKitManager.shared"),
            "SyncSettingsView should read CloudKit status through SyncSettingsStore instead of CloudKitManager.shared."
        )
        #expect(
            !viewSource.contains("AppSyncCoordinator.shared"),
            "SyncSettingsView should send sync intent through SyncSettingsStore instead of AppSyncCoordinator.shared."
        )
        #expect(
            !viewSource.contains("@AppStorage")
                && !viewSource.contains("SyncSettings.enabledKey"),
            "SyncSettingsView should delegate sync-enabled persistence to SyncSettingsStore."
        )
        #expect(
            storeSource.contains("SyncSettingsCloudKitStatusProvider(cloudKit: CloudKitManager.shared)"),
            "SyncSettingsStore live wiring should use a Settings-owned CloudKit status adapter."
        )
        #expect(
            storeSource.contains("final class SyncSettingsCloudKitStatusProvider"),
            "Settings CloudKit status projection should live in a Settings-owned adapter."
        )
        #expect(
            !storeSource.contains("extension CloudKitManager: SyncSettingsCloudStatusProviding"),
            "Settings should not attach feature status projection to the Core CloudKitManager type."
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
            !generalSettingsSource.contains("@AppStorage")
                && !generalSettingsSource.contains("UserDefaults.standard")
                && !generalSettingsSource.contains("PrivacyModeSettings.enabledKey")
                && !generalSettingsSource.contains("AnalyticsTracker.enabledKey")
                && !generalSettingsSource.contains("AppLanguage.applySelection"),
            "GeneralSettingsView should delegate persisted General preference reads, writes, and language side effects to its application store."
        )
        #expect(
            generalSettingsSource.contains("settingsStore: GeneralSettingsPreferenceStore"),
            "GeneralSettingsView should receive its General preference store explicitly."
        )
        #expect(
            !terminalSettingsSource.contains("TrustedHostsSettingsStore.shared"),
            "TerminalSettingsView should receive TrustedHostsSettingsStore from SettingsView."
        )
        #expect(
            !terminalSettingsSource.contains("@AppStorage")
                && !terminalSettingsSource.contains("UserDefaults.standard"),
            "TerminalSettingsView should delegate persisted Terminal preference reads and writes to its application store."
        )
        #expect(
            terminalSettingsSource.contains("settingsStore: TerminalSettingsPreferenceStore"),
            "TerminalSettingsView should receive its Terminal preference store explicitly."
        )
        #expect(
            !keychainSettingsSource.contains("SSHKeySettingsStore.shared"),
            "KeychainSettingsView should receive SSHKeySettingsStore from SettingsView."
        )
        #expect(
            settingsSource.contains("settingsStore: generalSettings")
                && settingsSource.contains("viewTabConfig: viewTabConfig"),
            "SettingsView should inject GeneralSettingsPreferenceStore and ViewTabConfigurationManager into GeneralSettingsView."
        )
        #expect(
            settingsSource.contains("settingsStore: terminalSettings")
                && settingsSource.contains("trustedHostsStore: trustedHostsStore"),
            "SettingsView should inject TerminalSettingsPreferenceStore and TrustedHostsSettingsStore into TerminalSettingsView."
        )
        #expect(
            settingsSource.contains("KeychainSettingsView(keyStore: keyStore)"),
            "SettingsView should inject SSHKeySettingsStore into KeychainSettingsView."
        )
    }

    @Test
    func aboutSettingsReceivesStoreManagerFromSettingsRoot() throws {
        // Given the About leaf view and Settings root SwiftUI source.
        let root = try sourceRoot()
        let aboutSettingsSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/Settings/UI/AboutSettingsView.swift")
        )
        let settingsSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/Settings/UI/SettingsView.swift")
        )

        // Then review-mode UI should render injected StoreManager state rather
        // than resolving the live purchase store by itself.
        #expect(
            !aboutSettingsSource.contains("StoreManager.shared"),
            "AboutSettingsView and ReviewModeSheet should receive StoreManager from SettingsView."
        )
        #expect(
            settingsSource.contains("AboutSettingsView(storeManager: storeManager)"),
            "SettingsView should inject StoreManager into AboutSettingsView."
        )
    }

    @Test
    func sfSymbolPickerReceivesCatalogAndRecentStoreFromCaller() throws {
        // Given the SF Symbol picker leaf view and its current form caller.
        let root = try sourceRoot()
        let pickerSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/Settings/UI/SFSymbolPickerView.swift")
        )
        let formSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalPresets/UI/Settings/TerminalPresetFormView.swift")
        )
        let servicesSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/Settings/Application/SFSymbolSettingsServices.swift")
        )

        // Then the picker should only render/search injected services, while
        // UserDefaults persistence and system catalog loading stay in Settings
        // Application services.
        #expect(
            !pickerSource.contains("RecentSymbolsManager.shared"),
            "SFSymbolPickerView should receive RecentSymbolsManager instead of resolving the live store."
        )
        #expect(
            !pickerSource.contains("SFSymbolsProvider.shared"),
            "SFSymbolPickerView should receive SFSymbolsProvider instead of resolving the live provider."
        )
        #expect(
            !pickerSource.contains("UserDefaults.standard") && !pickerSource.contains("CoreGlyphs.bundle"),
            "SFSymbolPickerView should not own persistence or CoreGlyphs catalog loading."
        )
        #expect(
            servicesSource.contains("final class SFSymbolsProvider") && servicesSource.contains("final class RecentSymbolsManager"),
            "SF Symbol catalog and recent-symbol persistence should live in Settings Application services."
        )
        #expect(
            formSource.contains("provider: symbolsProvider") && formSource.contains("recentManager: recentSymbolsManager"),
            "TerminalPresetFormView should pass injected symbol services into SFSymbolPickerView."
        )
        #expect(
            !formSource.contains("TerminalPresetManager.shared"),
            "TerminalPresetFormView should save presets through an injected application manager."
        )
    }

    @Test
    func transcriptionSettingsReceivesStoresFromSettingsRoot() throws {
        // Given the transcription settings leaf view and Settings root source.
        let root = try sourceRoot()
        let transcriptionSettingsSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/VoiceInput/UI/Settings/TranscriptionSettingsView.swift")
        )
        let settingsSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/Settings/UI/SettingsView.swift")
        )

        // Then the leaf view should render injected settings and model-download state
        // rather than resolving live stores or persistent settings by itself.
        #expect(
            !transcriptionSettingsSource.contains("self.init(modelDownloads: .shared)"),
            "TranscriptionSettingsView should not resolve VoiceModelDownloadStore.shared from leaf UI."
        )
        #expect(
            !transcriptionSettingsSource.contains("@AppStorage")
                && !transcriptionSettingsSource.contains("UserDefaults.standard"),
            "TranscriptionSettingsView should delegate persisted preference reads and writes to its application store."
        )
        #expect(
            transcriptionSettingsSource.contains("settingsStore: TranscriptionSettingsPreferenceStore"),
            "TranscriptionSettingsView should receive its persisted settings store explicitly."
        )
        #expect(
            settingsSource.contains("settingsStore: voiceSettings")
                && settingsSource.contains("modelDownloads: voiceModelDownloads"),
            "SettingsView should pass voice settings and model download stores into the transcription settings screen."
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
