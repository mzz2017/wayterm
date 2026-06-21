import Foundation
import Testing
@testable import VVTerm

// Test Context:
// These tests protect the Servers application-layer boundary that prepares
// Keychain-backed credentials and reusable SSH keys for ServerFormSheet.
// Server form UI may request form-ready credential values, but it must not
// decode stored key material or call KeychainManager directly. Fakes keep all
// keychain reads in memory; update this context only if server form credential
// ownership intentionally moves to another Servers application-layer type.
@Suite(.serialized)
@MainActor
struct ServerFormCredentialProviderTests {
    @Test
    func storedKeyMaterialDecodesPrivateKeyPassphraseAndPublicKeyForFormUse() throws {
        // Given a reusable SSH key entry backed by raw keychain data.
        let key = SSHKeyEntry(
            name: "Tencent",
            hasPassphrase: true,
            publicKey: "ssh-ed25519 public"
        )
        let library = FakeServerFormCredentialLibrary(
            entries: [key],
            keyData: [
                key.id: (
                    key: Data("private-key".utf8),
                    passphrase: "secret"
                )
            ]
        )
        let provider = ServerFormCredentialProvider(library: library)

        // When the server form asks for form-ready material.
        let material = try #require(try provider.storedSSHKeyMaterial(for: key))

        // Then decoding stays in the Servers application boundary.
        #expect(material.privateKey == "private-key")
        #expect(material.passphrase == "secret")
        #expect(material.publicKey == "ssh-ed25519 public")
    }

    @Test
    func matchingStoredKeyFindsSamePrivateKeyAndPassphrase() throws {
        // Given two reusable keys with different private key material.
        let matching = SSHKeyEntry(
            name: "Matching",
            hasPassphrase: true,
            publicKey: "ssh-ed25519 matching"
        )
        let other = SSHKeyEntry(name: "Other", hasPassphrase: false)
        let library = FakeServerFormCredentialLibrary(
            entries: [other, matching],
            keyData: [
                matching.id: (key: Data("private-key".utf8), passphrase: "secret"),
                other.id: (key: Data("other-key".utf8), passphrase: nil)
            ]
        )
        let provider = ServerFormCredentialProvider(library: library)

        // When the server form selects a stored key for loaded SSH credentials.
        let selected = provider.matchingStoredSSHKey(
            privateKey: "private-key",
            passphrase: "secret",
            authMethod: .sshKeyWithPassphrase
        )

        // Then the provider performs the keychain material comparison outside UI.
        #expect(selected == matching)
    }

    @Test
    func matchingStoredKeyRejectsDifferentPassphrase() throws {
        // Given a stored key whose private key text matches but passphrase does not.
        let key = SSHKeyEntry(name: "Protected", hasPassphrase: true)
        let library = FakeServerFormCredentialLibrary(
            entries: [key],
            keyData: [
                key.id: (key: Data("private-key".utf8), passphrase: "secret")
            ]
        )
        let provider = ServerFormCredentialProvider(library: library)

        // When loaded credentials use a different passphrase.
        let selected = provider.matchingStoredSSHKey(
            privateKey: "private-key",
            passphrase: "different",
            authMethod: .sshKeyWithPassphrase
        )

        // Then the provider keeps the UI from selecting the wrong stored key.
        #expect(selected == nil)
    }

    @Test
    func matchingStoredKeySkipsUnreadableCandidatesAndUsesLoadedPickerKeys() throws {
        // Given the picker already loaded a stale broken key before a valid key.
        let broken = SSHKeyEntry(name: "Broken", hasPassphrase: false)
        let matching = SSHKeyEntry(name: "Matching", hasPassphrase: false)
        let notDisplayed = SSHKeyEntry(name: "Not Displayed", hasPassphrase: false)
        let library = FakeServerFormCredentialLibrary(
            entries: [notDisplayed],
            keyData: [
                matching.id: (key: Data("private-key".utf8), passphrase: nil),
                notDisplayed.id: (key: Data("private-key".utf8), passphrase: nil)
            ],
            keyDataErrors: [
                broken.id: FakeServerFormCredentialError.readFailed
            ]
        )
        let provider = ServerFormCredentialProvider(library: library)

        // When edit mode tries to preselect a reusable key from the displayed picker list.
        let selected = provider.matchingStoredSSHKey(
            in: [broken, matching],
            privateKey: "private-key",
            passphrase: nil,
            authMethod: .sshKey
        )

        // Then the broken candidate is skipped and matching stays scoped to displayed keys.
        #expect(selected == matching)
    }

    @Test
    func storedKeyMaterialPreservesKeychainReadFailure() throws {
        // Given a keychain library that fails while reading stored key material.
        let key = SSHKeyEntry(name: "Broken")
        let library = FakeServerFormCredentialLibrary(entries: [key])
        library.keyDataError = FakeServerFormCredentialError.readFailed
        let provider = ServerFormCredentialProvider(library: library)

        // When the server form asks for stored key material.
        // Then the underlying failure remains distinguishable for UI error presentation.
        #expect(throws: FakeServerFormCredentialError.readFailed) {
            _ = try provider.storedSSHKeyMaterial(for: key)
        }
    }

    @Test
    func serverCredentialsAreLoadedThroughApplicationBoundary() throws {
        // Given a server whose credentials live behind the provider library.
        let server = Server(
            workspaceId: UUID(),
            name: "Tencent",
            host: "example.com",
            username: "root",
            authMethod: .sshKey
        )
        let credentials = ServerCredentials(
            serverId: server.id,
            password: nil,
            privateKey: Data("private-key".utf8),
            publicKey: Data("ssh-ed25519 public".utf8),
            passphrase: nil
        )
        let library = FakeServerFormCredentialLibrary(credentialsByServerID: [server.id: credentials])
        let provider = ServerFormCredentialProvider(library: library)

        // When edit mode asks for credentials.
        let loaded = try provider.credentials(for: server)

        // Then ServerFormSheet can populate fields without touching KeychainManager.
        #expect(loaded.privateKey == credentials.privateKey)
        #expect(loaded.publicKey == credentials.publicKey)
    }
}

private final class FakeServerFormCredentialLibrary: ServerFormCredentialLibrary {
    private let entries: [SSHKeyEntry]
    private let keyData: [UUID: (key: Data, passphrase: String?)]
    private let keyDataErrors: [UUID: Error]
    private let credentialsByServerID: [UUID: ServerCredentials]
    var keyDataError: Error?

    init(
        entries: [SSHKeyEntry] = [],
        keyData: [UUID: (key: Data, passphrase: String?)] = [:],
        keyDataErrors: [UUID: Error] = [:],
        credentialsByServerID: [UUID: ServerCredentials] = [:]
    ) {
        self.entries = entries
        self.keyData = keyData
        self.keyDataErrors = keyDataErrors
        self.credentialsByServerID = credentialsByServerID
    }

    func storedSSHKeys() -> [SSHKeyEntry] {
        entries
    }

    func storedSSHKeyData(for keyId: UUID) throws -> (key: Data, passphrase: String?)? {
        if let keyDataError {
            throw keyDataError
        }
        if let error = keyDataErrors[keyId] {
            throw error
        }
        return keyData[keyId]
    }

    func credentials(for server: Server) throws -> ServerCredentials {
        guard let credentials = credentialsByServerID[server.id] else {
            throw FakeServerFormCredentialError.missingCredentials
        }
        return credentials
    }
}

private enum FakeServerFormCredentialError: Error, Equatable {
    case readFailed
    case missingCredentials
}
