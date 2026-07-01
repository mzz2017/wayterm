import XCTest
@testable import Waterm

// Test Context:
// These tests protect terminal preset manager persistence and mutation rules.
// Fakes use isolated storage and no terminal launch; update only when preset
// manager behavior intentionally changes.

@MainActor
final class TerminalPresetManagerTests: XCTestCase {
    func testAddPresetPersistsPreset() throws {
        let (defaults, suiteName) = try makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let manager = TerminalPresetManager(defaults: defaults)

        manager.addPreset(name: "Claude", command: "claude", icon: "sparkles")

        XCTAssertEqual(manager.presets.count, 1)
        XCTAssertEqual(manager.presets.first?.name, "Claude")

        let reloaded = TerminalPresetManager(defaults: defaults)
        XCTAssertEqual(reloaded.presets.map(\.name), ["Claude"])
        XCTAssertEqual(reloaded.presets.first?.command, "claude")
        XCTAssertEqual(reloaded.presets.first?.icon, "sparkles")
    }

    func testUpdatePresetReplacesMatchingPreset() throws {
        let (defaults, suiteName) = try makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let manager = TerminalPresetManager(defaults: defaults)
        manager.addPreset(name: "Claude", command: "claude", icon: "terminal")

        var updated = try XCTUnwrap(manager.presets.first)
        updated.name = "Claude Code"
        updated.command = "claude --continue"
        updated.icon = "chevron.left.forwardslash.chevron.right"

        manager.updatePreset(updated)

        XCTAssertEqual(manager.presets.count, 1)
        XCTAssertEqual(manager.presets.first?.name, "Claude Code")
        XCTAssertEqual(manager.presets.first?.command, "claude --continue")
        XCTAssertEqual(manager.presets.first?.icon, "chevron.left.forwardslash.chevron.right")
    }

    func testDeletePresetRemovesPreset() throws {
        let (defaults, suiteName) = try makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let manager = TerminalPresetManager(defaults: defaults)
        manager.addPreset(name: "Claude", command: "claude")
        let presetID = try XCTUnwrap(manager.presets.first?.id)

        manager.deletePreset(id: presetID)

        XCTAssertTrue(manager.presets.isEmpty)
    }

    private func makeIsolatedDefaults() throws -> (defaults: UserDefaults, suiteName: String) {
        let suiteName = "TerminalPresetManagerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }
}
