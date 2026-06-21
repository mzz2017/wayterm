import Foundation
import Testing
@testable import VVTerm

// Test Context:
// These tests protect the Settings application-layer owner for reusable SSH key
// library import, delete, and generated-key persistence. SSH key operations are
// Keychain-backed destructive/persistence actions, so SwiftUI may send intent
// but must not call KeychainManager or own generation tasks directly. Fakes keep
// all keychain and key-generation work in memory; update this context only when
// reusable SSH key ownership intentionally moves to another Settings
// application-layer type.
@Suite(.serialized)
@MainActor
struct SSHKeySettingsStoreTests {
    @Test
    func importKeyStoresThroughApplicationOwnerAndRefreshesKeys() throws {
        // Given a Settings SSH key store backed by an in-memory key library.
        let library = FakeSSHKeyLibrary()
        let store = SSHKeySettingsStore(keyLibrary: library)

        // When Settings imports a private key.
        let entry = try store.importKey(
            name: "Imported Key",
            privateKeyPEM: "-----BEGIN OPENSSH PRIVATE KEY-----\nfixture\n-----END OPENSSH PRIVATE KEY-----",
            passphrase: "secret"
        )

        // Then the key library write is owned by the application store and the
        // visible key list is refreshed from the same owner.
        #expect(entry.name == "Imported Key")
        #expect(library.storedPrivateKeys[entry.id] != nil)
        #expect(library.storedPassphrases[entry.id] == "secret")
        #expect(store.storedKeys == [entry])
        #expect(store.errorMessage == nil)
    }

    @Test
    func deleteKeyRefreshesVisibleKeysAfterApplicationOwnedDeleteSucceeds() {
        // Given a Settings SSH key store showing two reusable keys.
        let removed = SSHKeyEntry(name: "Removed Key", createdAt: Date(timeIntervalSince1970: 1))
        let retained = SSHKeyEntry(name: "Retained Key", createdAt: Date(timeIntervalSince1970: 2))
        let library = FakeSSHKeyLibrary(entries: [removed, retained])
        let store = SSHKeySettingsStore(keyLibrary: library)
        store.loadKeys()

        // When Settings requests deletion through the application owner.
        store.deleteKey(removed)

        // Then the visible list is refreshed only after the backing library
        // removes the key.
        #expect(store.storedKeys == [retained])
        #expect(store.errorMessage == nil)
    }

    @Test
    func deleteKeyCapturesFailureWithoutMutatingVisibleKeys() {
        // Given a Settings SSH key store showing one key and a key library that
        // rejects deletion.
        let existing = SSHKeyEntry(name: "Existing Key", createdAt: Date(timeIntervalSince1970: 1))
        let library = FakeSSHKeyLibrary(entries: [existing])
        library.deleteError = FakeSSHKeyLibraryError.deleteFailed
        let store = SSHKeySettingsStore(keyLibrary: library)
        store.loadKeys()

        // When Settings requests deletion.
        store.deleteKey(existing)

        // Then the failure is captured for UI presentation and the visible list
        // is not refreshed as if the destructive action succeeded.
        #expect(store.storedKeys == [existing])
        #expect(
            store.errorMessage?.contains("delete") == true,
            "Deletion failure should remain distinguishable to Settings UI."
        )
    }

    @Test
    func generateKeyRequestIsTrackedAndRefreshesAfterSave() async {
        // Given a Settings SSH key store with a delayed fake generator.
        let library = FakeSSHKeyLibrary()
        let generator = DelayedSSHKeyGenerator()
        let store = SSHKeySettingsStore(keyLibrary: library, keyGenerator: generator)

        // When Settings requests key generation and persistence.
        let requestID = store.generateKey(
            name: "Generated Key",
            type: .ed25519,
            passphrase: nil
        )
        #expect(
            store.pendingGenerationTaskIDs.contains(requestID),
            "Generated-key persistence should be tracked by the Settings application store."
        )

        await generator.waitUntilGenerationStarted()
        await generator.finish()
        await store.waitForGenerationTask(requestID)

        // Then the tracked request has finished and the generated key appears in
        // the refreshed key list.
        #expect(!store.pendingGenerationTaskIDs.contains(requestID))
        #expect(store.storedKeys.count == 1)
        #expect(store.storedKeys.first?.name == "Generated Key")
        #expect(store.errorMessage == nil)
    }
}

@MainActor
private final class FakeSSHKeyLibrary: SSHKeyLibrary {
    private(set) var entries: [SSHKeyEntry]
    private(set) var storedPrivateKeys: [UUID: Data] = [:]
    private(set) var storedPassphrases: [UUID: String] = [:]
    var deleteError: Error?

    init(entries: [SSHKeyEntry] = []) {
        self.entries = entries
    }

    func storedSSHKeys() -> [SSHKeyEntry] {
        entries
    }

    func storeSSHKeyEntry(
        name: String,
        privateKey: Data,
        passphrase: String?,
        keyType: SSHKeyType?,
        publicKey: String?
    ) throws -> SSHKeyEntry {
        let entry = SSHKeyEntry(
            name: name,
            hasPassphrase: passphrase?.isEmpty == false,
            createdAt: Date(timeIntervalSince1970: TimeInterval(entries.count + 1)),
            keyType: keyType,
            publicKey: publicKey
        )
        entries = [entry] + entries
        storedPrivateKeys[entry.id] = privateKey
        storedPassphrases[entry.id] = passphrase
        return entry
    }

    func deleteStoredSSHKey(_ keyId: UUID) throws {
        if let deleteError {
            throw deleteError
        }
        entries.removeAll { $0.id == keyId }
        storedPrivateKeys.removeValue(forKey: keyId)
        storedPassphrases.removeValue(forKey: keyId)
    }
}

private enum FakeSSHKeyLibraryError: LocalizedError {
    case deleteFailed

    var errorDescription: String? {
        switch self {
        case .deleteFailed:
            return "delete failed"
        }
    }
}

private actor DelayedSSHKeyGenerator: SSHKeyPairGenerating {
    private let started = SSHKeySettingsAsyncProbe()
    private let gate = SSHKeySettingsAsyncGate()

    func generate(type: SSHKeyType, comment: String) async throws -> GeneratedSSHKey {
        await started.mark()
        await gate.wait()
        return GeneratedSSHKey(
            privateKey: Data("generated-private-key".utf8),
            publicKey: "ssh-ed25519 generated-public-key \(comment)",
            keyType: type,
            fingerprint: "SHA256:generated"
        )
    }

    func waitUntilGenerationStarted() async {
        await started.wait()
    }

    func finish() async {
        await gate.open()
    }
}

private actor SSHKeySettingsAsyncProbe {
    private var isMarked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func mark() {
        isMarked = true
        let continuations = waiters
        waiters.removeAll()
        continuations.forEach { $0.resume() }
    }

    func wait() async {
        if isMarked {
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

private actor SSHKeySettingsAsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        isOpen = true
        let continuations = waiters
        waiters.removeAll()
        continuations.forEach { $0.resume() }
    }

    func wait() async {
        if isOpen {
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}
