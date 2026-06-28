import Foundation
import Testing
@testable import VVTerm

// Test Context:
// These tests protect the runtime preference boundary consumed by terminal UI
// and surface wrappers. Settings may continue to write the legacy UserDefaults
// keys, but terminal runtime views should read a single injected application
// store. Update these tests only if those persisted keys or runtime defaults
// intentionally change.

@Suite
@MainActor
struct TerminalRuntimePreferencesStoreTests {
    private let suiteName: String
    private let defaults: UserDefaults

    init() {
        suiteName = "TerminalRuntimePreferencesStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test
    func loadsDefaultRuntimePreferencesWhenPreferencesAreMissing() {
        // Given a fresh defaults suite with no terminal runtime preferences.
        clearKeys()

        // When the runtime preference store is created.
        let store = makeStore()

        // Then runtime defaults preserve the existing terminal behavior.
        #expect(store.terminalThemeName == "Aizen Dark")
        #expect(store.terminalThemeNameLight == "Aizen Light")
        #expect(store.usePerAppearanceTheme == true)
        #expect(store.autoReconnectEnabled == true)
        #expect(store.terminalVoiceButtonEnabled == true)
    }

    @Test
    func refreshReloadsRuntimePreferencesFromPersistence() {
        // Given a runtime preference store backed by isolated UserDefaults.
        clearKeys()
        let store = makeStore()

        // When Settings or another owner writes the legacy persisted keys.
        defaults.set("Tokyo Night", forKey: CloudKitSyncConstants.terminalThemeNameKey)
        defaults.set("GitHub Light", forKey: CloudKitSyncConstants.terminalThemeNameLightKey)
        defaults.set(false, forKey: CloudKitSyncConstants.terminalUsePerAppearanceThemeKey)
        defaults.set(false, forKey: UserDefaultsTerminalRuntimePreferencesPersistence.sshAutoReconnectKey)
        defaults.set(false, forKey: UserDefaultsTerminalRuntimePreferencesPersistence.terminalVoiceButtonEnabledKey)
        store.refreshFromPersistence()

        // Then terminal runtime consumers see the updated injected state.
        #expect(store.terminalThemeName == "Tokyo Night")
        #expect(store.terminalThemeNameLight == "GitHub Light")
        #expect(store.usePerAppearanceTheme == false)
        #expect(store.autoReconnectEnabled == false)
        #expect(store.terminalVoiceButtonEnabled == false)
    }

    @Test
    func deinitInvalidatesPreferenceChangeObserver() {
        let notificationCenter = NotificationCenter()
        let persistence = CountingTerminalRuntimePreferencesPersistence()
        var store: TerminalRuntimePreferencesStore? = TerminalRuntimePreferencesStore(
            persistence: persistence,
            notificationCenter: notificationCenter
        )

        // Given the runtime preference store registered for persistence change notifications.
        #expect(persistence.loadCount == 1)
        #expect(store?.terminalThemeName == "Aizen Dark")

        // When the store is released and a late notification arrives.
        store = nil
        notificationCenter.post(name: UserDefaults.didChangeNotification, object: persistence.changeNotificationObject)

        // Then the observer has been invalidated and no late reload is attempted.
        #expect(persistence.loadCount == 1)
    }

    private func makeStore() -> TerminalRuntimePreferencesStore {
        TerminalRuntimePreferencesStore(
            persistence: UserDefaultsTerminalRuntimePreferencesPersistence(defaults: defaults)
        )
    }

    private func clearKeys() {
        [
            CloudKitSyncConstants.terminalThemeNameKey,
            CloudKitSyncConstants.terminalThemeNameLightKey,
            CloudKitSyncConstants.terminalUsePerAppearanceThemeKey,
            UserDefaultsTerminalRuntimePreferencesPersistence.sshAutoReconnectKey,
            UserDefaultsTerminalRuntimePreferencesPersistence.terminalVoiceButtonEnabledKey,
        ].forEach(defaults.removeObject(forKey:))
    }
}

@MainActor
private final class CountingTerminalRuntimePreferencesPersistence: TerminalRuntimePreferencesPersisting {
    private(set) var loadCount = 0
    let changeNotificationObject: Any? = NSObject()

    func loadTerminalRuntimePreferences() -> TerminalRuntimePreferenceSnapshot {
        loadCount += 1
        return TerminalRuntimePreferenceSnapshot(
            terminalThemeName: "Aizen Dark",
            terminalThemeNameLight: "Aizen Light",
            usePerAppearanceTheme: true,
            autoReconnectEnabled: true,
            terminalVoiceButtonEnabled: true
        )
    }
}
