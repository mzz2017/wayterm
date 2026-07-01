import Foundation
import Testing

// Test Context:
// These tests protect shared type ownership around ServerManager. Product
// entitlement limits belong to Store domain, and cross-feature app errors belong
// to Core. Update only when those shared ownership boundaries intentionally move.

struct ServerManagerSharedTypeBoundaryTests {
    @Test
    func serverManagerDoesNotOwnSharedLimitAndErrorTypes() throws {
        let root = try sourceRoot()
        let managerSource = try source(
            at: root.appendingPathComponent("Waterm/Features/Servers/Application/ServerManager.swift")
        )
        let limitsSource = try source(
            at: root.appendingPathComponent("Waterm/Features/Store/Domain/FreeTierLimits.swift")
        )
        let errorSource = try source(
            at: root.appendingPathComponent("Waterm/Core/WatermError.swift")
        )

        // Given the Servers application manager source.
        #expect(
            !managerSource.contains("enum FreeTierLimits"),
            "ServerManager should not own shared Store entitlement limit types."
        )
        #expect(
            !managerSource.contains("enum WatermError"),
            "ServerManager should not own cross-feature app error types."
        )

        // Then shared types live in their owning layers.
        #expect(limitsSource.contains("enum FreeTierLimits"))
        #expect(errorSource.contains("enum WatermError"))
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
