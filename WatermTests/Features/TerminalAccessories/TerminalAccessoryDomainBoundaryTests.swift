import Foundation
import Testing

// Test Context:
// These tests protect TerminalAccessories Domain ownership after the accessory
// model split. Keyboard/system action mapping and persisted profile rules are
// separate model families; putting them back into one broad source file makes
// validation, migration, and UI customization regressions harder to localize.
// Update this test only if the Domain ownership rule intentionally changes.
struct TerminalAccessoryDomainBoundaryTests {
    @Test
    func accessoryDomainModelsStaySplitByResponsibility() throws {
        let root = try sourceRoot()
        let domain = root.appendingPathComponent("Waterm/Features/TerminalAccessories/Domain")
        let legacyModels = domain.appendingPathComponent("TerminalAccessoryModels.swift")
        let keyboardModels = domain.appendingPathComponent("TerminalAccessoryKeyboardModels.swift")
        let profileModels = domain.appendingPathComponent("TerminalAccessoryProfileModels.swift")

        let keyboardSource = try source(at: keyboardModels)
        let profileSource = try source(at: profileModels)

        #expect(
            !FileManager.default.fileExists(atPath: legacyModels.path),
            "TerminalAccessories Domain should not reintroduce a broad TerminalAccessoryModels.swift superfile."
        )
        #expect(
            keyboardSource.contains("enum TerminalAccessoryShortcutKey"),
            "Keyboard shortcut key mapping should live in TerminalAccessoryKeyboardModels.swift."
        )
        #expect(
            keyboardSource.contains("enum TerminalAccessorySystemActionID"),
            "System action metadata should live in TerminalAccessoryKeyboardModels.swift."
        )
        #expect(
            !keyboardSource.contains("struct TerminalAccessoryProfile"),
            "Keyboard models should not own persisted accessory profile shape or merge rules."
        )
        #expect(
            profileSource.contains("struct TerminalAccessoryProfile"),
            "Persisted accessory profile shape should live in TerminalAccessoryProfileModels.swift."
        )
        #expect(
            profileSource.contains("static func merged"),
            "Accessory profile merge rules should stay with the persisted profile model."
        )
        #expect(
            !profileSource.contains("enum TerminalAccessoryShortcutKey"),
            "Profile models should reference keyboard key models without owning their mapping table."
        )

        for file in try swiftFiles(in: domain) {
            let lineCount = try source(at: file).split(separator: "\n", omittingEmptySubsequences: false).count
            #expect(
                lineCount < 800,
                "\(file.lastPathComponent) should stay below the AGENTS.md superfile review threshold."
            )
        }
    }

    private func swiftFiles(in directory: URL) throws -> [URL] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        return urls.filter { $0.pathExtension == "swift" }
    }

    private func source(at url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    private func sourceRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.lastPathComponent != "WatermTests" {
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
