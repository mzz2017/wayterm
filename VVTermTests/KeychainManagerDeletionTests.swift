import Foundation
import Testing
@testable import VVTerm

// Test Context:
// These tests protect destructive Keychain deletion behavior. The fake store
// models Security.framework failures so server and reusable-key metadata cannot
// report success while private credential bytes remain in Keychain.
@Suite(.serialized)
@MainActor
struct KeychainManagerDeletionTests {
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
