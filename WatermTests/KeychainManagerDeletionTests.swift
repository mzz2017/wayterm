import Foundation
import Testing
@testable import Waterm

// Test Context:
// These tests protect destructive Keychain deletion behavior. The fake store
// models Security.framework failures and credential replacement so server and
// reusable-key metadata cannot report success while private credential bytes
// remain in Keychain. They also protect Waterm's sync setting as the
// cross-device total control for credential writes: disabling CloudKit sync must
// keep secrets device-local. Update these tests only when KeychainManager
// intentionally changes whether omitted credential parts are retained or
// removed, or Waterm intentionally splits credential sync from the app-wide sync
// toggle.
@Suite(.serialized)
@MainActor
struct KeychainManagerDeletionTests {
    @Test
    func storingSSHKeyWithoutOptionalMetadataClearsPreviouslyStoredMetadata() throws {
        let serverId = UUID(uuidString: "00000000-0000-0000-0000-00000000D000")!
        let store = RecordingKeychainStore()
        let manager = KeychainManager(store: store)

        // Given an existing server SSH key with saved optional metadata.
        try manager.storeSSHKey(
            for: serverId,
            privateKey: Data("old-private-key".utf8),
            passphrase: "old-passphrase",
            publicKey: Data("old-public-key".utf8)
        )

        // When the same server key is replaced without optional metadata.
        try manager.storeSSHKey(
            for: serverId,
            privateKey: Data("new-private-key".utf8),
            passphrase: nil
        )

        // Then later credential lookup must not revive the old secret.
        let storedKey = try #require(try manager.getSSHKey(for: serverId))
        #expect(storedKey.key == Data("new-private-key".utf8))
        #expect(
            storedKey.passphrase == nil,
            "Replacing an SSH key without a passphrase must delete any previous passphrase for that server."
        )
        #expect(
            storedKey.publicKey == nil,
            "Replacing an SSH key without a public key must delete any previous public key for that server."
        )
    }

    @Test
    func deleteCredentialsPropagatesKeychainDeleteFailure() throws {
        let serverId = UUID(uuidString: "00000000-0000-0000-0000-00000000D001")!
        let failingKey = "server.\(serverId.uuidString).sshkey"
        let store = RecordingKeychainStore(failingDeletes: [failingKey: KeychainError.unhandled(-34018)])
        let manager = KeychainManager(store: store)

        do {
            try manager.deleteCredentials(for: serverId)
            Issue.record("Expected deleteCredentials to propagate the Keychain delete failure")
        } catch KeychainError.unhandled(let status) {
            #expect(status == -34018)
        } catch {
            Issue.record("Expected KeychainError.unhandled, got \(error)")
        }

        #expect(
            !store.deletedKeys.contains("server.\(serverId.uuidString).passphrase"),
            "Deletion should stop and report failure before claiming later credential keys were removed."
        )
    }

    @Test
    func deleteStoredSSHKeyKeepsIndexWhenPrivateKeyDeleteFails() throws {
        let keyId = UUID(uuidString: "00000000-0000-0000-0000-00000000D002")!
        let entry = SSHKeyEntry(id: keyId, name: "Reusable", createdAt: Date(timeIntervalSince1970: 1))
        let indexData = try JSONEncoder().encode([entry])
        let failingKey = "sshkey.\(keyId.uuidString).data"
        let store = RecordingKeychainStore(
            storedData: ["waterm.sshkeys.index": indexData],
            failingDeletes: [failingKey: KeychainError.unhandled(-34018)]
        )
        let manager = KeychainManager(store: store)

        do {
            try manager.deleteStoredSSHKey(keyId)
            Issue.record("Expected deleteStoredSSHKey to propagate the Keychain delete failure")
        } catch KeychainError.unhandled(let status) {
            #expect(status == -34018)
        } catch {
            Issue.record("Expected KeychainError.unhandled, got \(error)")
        }

        let savedIndex = try #require(store.storedData["waterm.sshkeys.index"])
        let savedEntries = try JSONDecoder().decode([SSHKeyEntry].self, from: savedIndex)
        #expect(
            savedEntries == [entry],
            "Reusable-key index must not hide a key when its private bytes failed to delete."
        )
    }

    @Test
    func cloudflareServiceTokenWriteFailurePreservesPreviousTokenPair() throws {
        let serverId = UUID(uuidString: "00000000-0000-0000-0000-00000000D003")!
        let idKey = "server.\(serverId.uuidString).cloudflare.clientid"
        let secretKey = "server.\(serverId.uuidString).cloudflare.clientsecret"
        let store = RecordingKeychainStore(
            storedData: [
                idKey: Data("old-client-id".utf8),
                secretKey: Data("old-client-secret".utf8)
            ],
            failingSets: [
                .init(key: secretKey, data: Data("new-client-secret".utf8)): KeychainError.unhandled(-34018)
            ]
        )
        let manager = KeychainManager(store: store)

        // Given a Cloudflare service token replacement fails after the first
        // field write has been attempted.
        do {
            try manager.storeCloudflareServiceToken(
                for: serverId,
                clientID: "new-client-id",
                clientSecret: "new-client-secret"
            )
            Issue.record("Expected storeCloudflareServiceToken to propagate the Keychain set failure")
        } catch KeychainError.unhandled(let status) {
            #expect(status == -34018)
        } catch {
            Issue.record("Expected KeychainError.unhandled, got \(error)")
        }

        // Then the stored token pair must remain internally consistent.
        #expect(
            store.storedData[idKey] == Data("old-client-id".utf8),
            "A failed service-token replacement must not leave a new client ID paired with an old secret."
        )
        #expect(store.storedData[secretKey] == Data("old-client-secret".utf8))
    }

    @Test
    func serverCredentialWritesStayDeviceLocalWhenSyncPolicyIsDisabled() throws {
        let serverId = UUID(uuidString: "00000000-0000-0000-0000-00000000D004")!
        let store = RecordingKeychainStore()
        let manager = KeychainManager(store: store, usesICloudKeychainSync: { false })

        // Given Waterm's cross-device sync policy is disabled.

        // When server credential secrets are written.
        try manager.storePassword(for: serverId, password: "secret-password")
        try manager.storeSSHKey(
            for: serverId,
            privateKey: Data("private-key".utf8),
            passphrase: "key-passphrase",
            publicKey: Data("public-key".utf8)
        )
        try manager.storeCloudflareServiceToken(
            for: serverId,
            clientID: "client-id",
            clientSecret: "client-secret"
        )

        // Then each credential write stays device-local because the CloudKit
        // sync setting is the cross-device total control.
        let credentialWrites = store.setCalls.filter { call in
            call.key.hasPrefix("server.\(serverId.uuidString).")
        }
        #expect(!credentialWrites.isEmpty)
        #expect(
            credentialWrites.filter(\.iCloudSync).isEmpty,
            "Server credential secrets must not use iCloud Keychain when CloudKit sync is disabled."
        )
    }

    @Test
    func serverCredentialWritesUseICloudKeychainWhenSyncPolicyIsEnabled() throws {
        let serverId = UUID(uuidString: "00000000-0000-0000-0000-00000000D005")!
        let store = RecordingKeychainStore()
        let manager = KeychainManager(store: store, usesICloudKeychainSync: { true })

        // Given Waterm's cross-device sync policy is enabled.

        // When server credential secrets are written.
        try manager.storePassword(for: serverId, password: "secret-password")
        try manager.storeSSHKey(
            for: serverId,
            privateKey: Data("private-key".utf8),
            passphrase: "key-passphrase",
            publicKey: Data("public-key".utf8)
        )
        try manager.storeCloudflareServiceToken(
            for: serverId,
            clientID: "client-id",
            clientSecret: "client-secret"
        )
        _ = try manager.storeSSHKeyEntry(
            name: "Reusable",
            privateKey: Data("reusable-private-key".utf8),
            passphrase: "reusable-passphrase",
            publicKey: "ssh-ed25519 AAAA"
        )

        // Then every credential and reusable-key write remains iCloud
        // Keychain-capable.
        #expect(!store.setCalls.isEmpty)
        #expect(
            !store.setCalls.contains { !$0.iCloudSync },
            "Credential secrets should use iCloud Keychain when sync is enabled."
        )
    }
}

private final class RecordingKeychainStore: KeychainStoring, @unchecked Sendable {
    private(set) var setCalls: [SetCall] = []
    private(set) var storedData: [String: Data]
    private(set) var deletedKeys: [String] = []
    private let failingDeletes: [String: Error]
    private let failingSets: [SetWrite: Error]

    init(
        storedData: [String: Data] = [:],
        failingDeletes: [String: Error] = [:],
        failingSets: [SetWrite: Error] = [:]
    ) {
        self.storedData = storedData
        self.failingDeletes = failingDeletes
        self.failingSets = failingSets
    }

    func set(_ data: Data, forKey key: String, iCloudSync: Bool) throws {
        if let error = failingSets[SetWrite(key: key, data: data)] {
            throw error
        }
        setCalls.append(SetCall(key: key, data: data, iCloudSync: iCloudSync))
        storedData[key] = data
    }

    func get(_ key: String) throws -> Data? {
        storedData[key]
    }

    func delete(_ key: String) throws {
        if let error = failingDeletes[key] {
            throw error
        }
        deletedKeys.append(key)
        storedData.removeValue(forKey: key)
    }

    struct SetWrite: Hashable {
        let key: String
        let data: Data
    }

    struct SetCall: Equatable {
        let key: String
        let data: Data
        let iCloudSync: Bool
    }
}
