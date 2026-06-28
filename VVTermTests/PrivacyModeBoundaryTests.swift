import Foundation
import Testing

// Test Context:
// PrivacyMode is Core/Security infrastructure for masking sensitive strings.
// Server-specific display policy belongs to the Servers feature, so Core/Security
// must not import or extend Servers domain models. Update these tests only if the
// feature ownership boundary changes intentionally.
@Suite
struct PrivacyModeBoundaryTests {
    @Test
    func coreSecurityDoesNotOwnServerPrivacyDisplayPolicy() throws {
        let root = try sourceRoot()
        let privacyModeSource = try source(
            at: root.appendingPathComponent("VVTerm/Core/Security/PrivacyMode.swift")
        )
        let serverPrivacyDisplaySource = try source(
            at: root.appendingPathComponent("VVTerm/Features/Servers/UI/Server+PrivacyDisplay.swift")
        )

        // Given Core/Security owns the generic privacy mask helpers.
        #expect(
            privacyModeSource.contains("enum SensitiveContentMask"),
            "Core/Security should keep the generic sensitive-content masking helper."
        )

        // When server privacy display needs feature domain fields.
        #expect(
            !privacyModeSource.contains("extension Server"),
            "Core/Security should not extend Servers feature domain models."
        )

        // Then Servers UI owns the display policy that combines Server with privacy masking.
        #expect(
            serverPrivacyDisplaySource.contains("extension Server"),
            "Servers feature UI should own Server privacy display helpers."
        )
        #expect(
            serverPrivacyDisplaySource.contains("SensitiveContentMask"),
            "Servers feature UI should adapt Core/Security masking without moving Server policy into Core."
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
