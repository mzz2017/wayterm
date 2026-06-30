import Foundation
import Testing
@testable import VVTerm

// Test Context:
// Protects Servers' credential replacement policy while Keychain operations are
// hidden behind a feature-owned service boundary. Fakes record requested writes
// only; update these tests when the app intentionally changes which credentials
// survive each connection/authentication mode.
@MainActor
struct ServerCredentialPersistenceTests {
    @Test
    func replacesStoredCredentialsBeforeWritingSelectedAuthCredential() throws {
        let library = RecordingCredentialLibrary()
        let persistence = ServerCredentialPersistence(library: library)
        let server = makeServer(authMethod: .password)
        var credentials = ServerCredentials(serverId: server.id)
        credentials.password = "secret"

        try persistence.storeCredentials(for: server, credentials: credentials)

        #expect(library.events == [
            .deleteCredentials(server.id),
            .storePassword(server.id, "secret")
        ])
    }

    @Test
    func clearsOldPassphraseBeforeWritingKeyWithoutSubmittedPassphrase() throws {
        let library = RecordingCredentialLibrary()
        let persistence = ServerCredentialPersistence(library: library)
        let server = makeServer(authMethod: .sshKeyWithPassphrase)
        let privateKey = Data("private-key".utf8)
        let publicKey = Data("public-key".utf8)
        var credentials = ServerCredentials(serverId: server.id)
        credentials.sshKey = privateKey
        credentials.sshPassphrase = ""
        credentials.publicKey = publicKey

        try persistence.storeCredentials(for: server, credentials: credentials)

        #expect(library.events == [
            .deleteCredentials(server.id),
            .storeSSHKey(server.id, privateKey, nil, publicKey)
        ])
    }

    @Test
    func tailscaleDeletesStoredCredentialsWithoutWritingAuthMaterial() throws {
        let library = RecordingCredentialLibrary()
        let persistence = ServerCredentialPersistence(library: library)
        let server = makeServer(connectionMode: .tailscale, authMethod: .password)
        var credentials = ServerCredentials(serverId: server.id)
        credentials.password = "ignored"

        try persistence.storeCredentials(for: server, credentials: credentials)

        #expect(library.events == [
            .deleteCredentials(server.id)
        ])
    }

    @Test
    func replacesCredentialsBeforeWritingCloudflareServiceToken() throws {
        let library = RecordingCredentialLibrary()
        let persistence = ServerCredentialPersistence(library: library)
        let server = makeServer(
            connectionMode: .cloudflare,
            authMethod: .password,
            cloudflareAccessMode: .serviceToken
        )
        var credentials = ServerCredentials(serverId: server.id)
        credentials.password = "secret"
        credentials.cloudflareClientID = "client-id"
        credentials.cloudflareClientSecret = "client-secret"

        try persistence.storeCredentials(for: server, credentials: credentials)

        #expect(library.events == [
            .deleteCredentials(server.id),
            .storePassword(server.id, "secret"),
            .storeCloudflareServiceToken(server.id, "client-id", "client-secret")
        ])
    }

    @Test
    func deleteCredentialsForwardsToCredentialLibrary() throws {
        let library = RecordingCredentialLibrary()
        let persistence = ServerCredentialPersistence(library: library)
        let serverId = UUID()

        try persistence.deleteCredentials(for: serverId)

        #expect(library.events == [.deleteCredentials(serverId)])
    }

    private func makeServer(
        connectionMode: SSHConnectionMode = .standard,
        authMethod: AuthMethod,
        cloudflareAccessMode: CloudflareAccessMode? = nil
    ) -> Server {
        Server(
            workspaceId: UUID(),
            name: "Credential Host",
            host: "credentials.example.com",
            username: "root",
            connectionMode: connectionMode,
            authMethod: authMethod,
            cloudflareAccessMode: cloudflareAccessMode
        )
    }
}

@MainActor
private final class RecordingCredentialLibrary: ServerCredentialWritingLibrary {
    enum Event: Equatable {
        case deleteCredentials(UUID)
        case storePassword(UUID, String)
        case storeSSHKey(UUID, Data, String?, Data?)
        case storeCloudflareServiceToken(UUID, String, String)
    }

    private(set) var events: [Event] = []

    func deleteCredentials(for serverId: UUID) throws {
        events.append(.deleteCredentials(serverId))
    }

    func storePassword(for serverId: UUID, password: String) throws {
        events.append(.storePassword(serverId, password))
    }

    func storeSSHKey(for serverId: UUID, privateKey: Data, passphrase: String?, publicKey: Data?) throws {
        events.append(.storeSSHKey(serverId, privateKey, passphrase, publicKey))
    }

    func storeCloudflareServiceToken(for serverId: UUID, clientID: String, clientSecret: String) throws {
        events.append(.storeCloudflareServiceToken(serverId, clientID, clientSecret))
    }
}
