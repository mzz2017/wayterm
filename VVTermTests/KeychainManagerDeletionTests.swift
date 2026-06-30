import Foundation
import Testing
@testable import VVTerm

// Test Context:
// These tests protect destructive Keychain deletion behavior. The fake store
// models Security.framework failures and credential replacement so server and
// reusable-key metadata cannot report success while private credential bytes
// remain in Keychain. Update these tests only when KeychainManager intentionally
// changes whether omitted credential parts are retained or removed.
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
            storedData: ["vvterm.sshkeys.index": indexData],
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

        let savedIndex = try #require(store.storedData["vvterm.sshkeys.index"])
        let savedEntries = try JSONDecoder().decode([SSHKeyEntry].self, from: savedIndex)
        #expect(
            savedEntries == [entry],
            "Reusable-key index must not hide a key when its private bytes failed to delete."
        )
    }
}

private final class RecordingKeychainStore: KeychainStoring, @unchecked Sendable {
    private(set) var storedData: [String: Data]
    private(set) var deletedKeys: [String] = []
    private let failingDeletes: [String: Error]

    init(storedData: [String: Data] = [:], failingDeletes: [String: Error] = [:]) {
        self.storedData = storedData
        self.failingDeletes = failingDeletes
    }

    func set(_ data: Data, forKey key: String, iCloudSync: Bool) throws {
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
}
