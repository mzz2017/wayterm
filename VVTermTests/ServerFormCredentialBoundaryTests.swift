import Foundation
import Testing

// Test Context:
// These tests protect the Servers UI/Application boundary for server form
// credential reads. ServerFormSheet may render fields and send form intent, but
// reusable key and server credential reads must stay behind a Servers
// application-layer provider. The tests inspect source placement only; update
// them only when this boundary intentionally moves to another application type.
@Suite
struct ServerFormCredentialBoundaryTests {
    @Test
    func serverFormSheetDoesNotReadKeychainManagerDirectly() throws {
        // Given the server form SwiftUI source.
        let root = try sourceRoot()
        let source = try source(
            at: root.appendingPathComponent("VVTerm/Features/Servers/UI/ServerDetail/ServerFormSheet.swift")
        )

        // Then credential and stored-key reads must go through the Servers
        // application provider instead of directly touching KeychainManager.
        #expect(
            !source.contains("KeychainManager.shared"),
            "ServerFormSheet should call ServerFormCredentialProvider instead of KeychainManager.shared."
        )
        #expect(
            source.contains("private let credentialProvider: ServerFormCredentialProvider"),
            "ServerFormSheet should hold the Servers application credential provider as its boundary dependency."
        )
        #expect(
            source.contains("credentialProvider.credentials(for: server)"),
            "ServerFormSheet should load edit credentials through the Servers application provider."
        )
    }

    @Test
    func serverFormCredentialProviderReceivesKeychainFromInfrastructure() throws {
        // Given the Servers application credential provider and its
        // infrastructure adapter.
        let root = try sourceRoot()
        let providerSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/Servers/Application/ServerFormCredentialProvider.swift")
        )
        let infrastructureSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/Servers/Infrastructure/ServerFormCredentialProvider+Keychain.swift")
        )

        // Then Application owns form credential preparation, while Keychain
        // wiring stays in Infrastructure.
        #expect(providerSource.contains("protocol ServerFormCredentialLibrary"))
        #expect(providerSource.contains("init(library: any ServerFormCredentialLibrary)"))
        #expect(!providerSource.contains("KeychainManager.shared"))
        #expect(infrastructureSource.contains("extension KeychainManager: ServerFormCredentialLibrary"))
        #expect(infrastructureSource.contains("ServerFormCredentialProvider(library: KeychainManager.shared)"))
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
