import XCTest
@testable import Waterm

// Test Context:
// These tests protect view-tab configuration persistence and ordering. Fakes use
// isolated configuration storage and no live connection views; update only when
// configuration semantics intentionally change.

@MainActor
final class ViewTabConfigurationManagerTests: XCTestCase {
    private func makeDefaults(testName: String = #function) -> UserDefaults {
        let suiteName = "WatermTests.ViewTabConfiguration.\(testName)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    func testHiddenDefaultFallsBackToFirstVisibleTab() {
        let manager = ViewTabConfigurationManager(defaults: makeDefaults())
        manager.setDefaultTab(ConnectionViewTab.terminal.id)
        manager.setVisibility(for: ConnectionViewTab.terminal.id, isVisible: false)

        XCTAssertEqual(manager.effectiveDefaultTab(), ConnectionViewTab.stats.id)
    }

    func testCannotHideLastVisibleTab() {
        let manager = ViewTabConfigurationManager(defaults: makeDefaults())
        manager.setVisibility(for: ConnectionViewTab.terminal.id, isVisible: false)
        manager.setVisibility(for: ConnectionViewTab.files.id, isVisible: false)
        manager.setVisibility(for: ConnectionViewTab.stats.id, isVisible: false)

        XCTAssertTrue(manager.showStatsTab)
        XCTAssertEqual(manager.currentVisibleTabs, [ConnectionViewTab.stats])
    }
}
