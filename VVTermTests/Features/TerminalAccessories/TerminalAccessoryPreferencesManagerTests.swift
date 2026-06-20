import XCTest
@testable import VVTerm

// Test Context:
// These tests protect terminal accessory preference persistence and defaults.
// Fakes use isolated storage and no keyboard UI; update only when preference
// storage or defaults intentionally change.

@MainActor
final class TerminalAccessoryPreferencesManagerTests: XCTestCase {
    private var syncWasEnabledObject: Any?
    private var defaultsSuiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        syncWasEnabledObject = UserDefaults.standard.object(forKey: SyncSettings.enabledKey)
        UserDefaults.standard.set(false, forKey: SyncSettings.enabledKey)

        defaultsSuiteName = "TerminalAccessoryPreferencesManagerTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuiteName)
        defaults.removePersistentDomain(forName: defaultsSuiteName)
    }

    override func tearDown() {
        if let syncWasEnabledObject {
            UserDefaults.standard.set(syncWasEnabledObject, forKey: SyncSettings.enabledKey)
        } else {
            UserDefaults.standard.removeObject(forKey: SyncSettings.enabledKey)
        }

        defaults.removePersistentDomain(forName: defaultsSuiteName)
        defaults = nil
        defaultsSuiteName = nil
        syncWasEnabledObject = nil
        super.tearDown()
    }

    func testCreateCustomActionPersistsAndUpdatesProfileMetadata() throws {
        let manager = TerminalAccessoryPreferencesManager(defaults: defaults)

        let action = try manager.createCustomAction(
            title: "List Files",
            kind: .command,
            commandContent: "ls -la",
            commandSendMode: .insertAndEnter,
            shortcutKey: .l,
            shortcutModifiers: .init(control: true)
        )

        XCTAssertEqual(manager.customActions.map(\.id), [action.id])
        XCTAssertEqual(manager.profile.lastWriterDeviceId, DeviceIdentity.id)
        XCTAssertEqual(manager.profile.customActions.first?.commandContent, "ls -la")
        XCTAssertNotNil(defaults.data(forKey: TerminalAccessoryProfile.defaultsKey))
    }

    func testResetToDefaultLayoutRestoresActiveItems() {
        let manager = TerminalAccessoryPreferencesManager(defaults: defaults)
        manager.removeActiveItem(.system(.escape))

        XCTAssertNotEqual(manager.activeItems, TerminalAccessoryProfile.defaultActiveItems)

        manager.resetToDefaultLayout()

        XCTAssertEqual(manager.activeItems, TerminalAccessoryProfile.defaultActiveItems)
        XCTAssertEqual(manager.profile.lastWriterDeviceId, DeviceIdentity.id)
    }
}
