import Combine
import Foundation

@MainActor
protocol SSHKeyLibrary: AnyObject {
    func storedSSHKeys() -> [SSHKeyEntry]
    func storeSSHKeyEntry(
        name: String,
        privateKey: Data,
        passphrase: String?,
        keyType: SSHKeyType?,
        publicKey: String?
    ) throws -> SSHKeyEntry
    func deleteStoredSSHKey(_ keyId: UUID) throws
}

extension KeychainManager: SSHKeyLibrary {
    func storedSSHKeys() -> [SSHKeyEntry] {
        getStoredSSHKeys()
    }
}

protocol SSHKeyPairGenerating {
    func generate(type: SSHKeyType, comment: String) async throws -> GeneratedSSHKey
}

struct DefaultSSHKeyPairGenerator: SSHKeyPairGenerating {
    func generate(type: SSHKeyType, comment: String) async throws -> GeneratedSSHKey {
        try SSHKeyGenerator.generate(type: type, comment: comment)
    }
}

@MainActor
final class SSHKeySettingsStore: ObservableObject {
    static let shared = SSHKeySettingsStore()

    @Published private(set) var storedKeys: [SSHKeyEntry] = []
    @Published private(set) var errorMessage: String?

    private let keyLibrary: any SSHKeyLibrary
    private let keyGenerator: any SSHKeyPairGenerating
    private var generationTasks: [UUID: Task<Void, Never>] = [:]

    var pendingGenerationTaskIDs: Set<UUID> {
        Set(generationTasks.keys)
    }

    init(
        keyLibrary: (any SSHKeyLibrary)? = nil,
        keyGenerator: (any SSHKeyPairGenerating)? = nil
    ) {
        self.keyLibrary = keyLibrary ?? KeychainManager.shared
        self.keyGenerator = keyGenerator ?? DefaultSSHKeyPairGenerator()
    }

    func loadKeys() {
        storedKeys = keyLibrary.storedSSHKeys()
    }

    func importKey(
        name: String,
        privateKeyPEM: String,
        passphrase: String?
    ) throws -> SSHKeyEntry {
        do {
            guard let keyData = privateKeyPEM.data(using: .utf8) else {
                throw KeychainError.encodingFailed
            }
            let normalizedPassphrase = normalizedPassphrase(passphrase)
            let publicKey = SSHPublicKeyDeriver.publicKey(
                fromPrivateKeyPEM: privateKeyPEM,
                passphrase: normalizedPassphrase
            )
            let entry = try keyLibrary.storeSSHKeyEntry(
                name: name,
                privateKey: keyData,
                passphrase: normalizedPassphrase,
                keyType: nil,
                publicKey: publicKey
            )
            loadKeys()
            errorMessage = nil
            return entry
        } catch {
            errorMessage = String(format: String(localized: "Failed to save key: %@"), error.localizedDescription)
            throw error
        }
    }

    func deleteKey(_ key: SSHKeyEntry) {
        do {
            try keyLibrary.deleteStoredSSHKey(key.id)
            loadKeys()
            errorMessage = nil
        } catch {
            errorMessage = String(format: String(localized: "Failed to delete key: %@"), error.localizedDescription)
        }
    }

    @discardableResult
    func generateKey(
        name: String,
        type: SSHKeyType,
        passphrase: String?,
        onSaved: ((SSHKeyEntry) -> Void)? = nil,
        onFailed: ((String) -> Void)? = nil
    ) -> UUID {
        let requestID = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                generationTasks.removeValue(forKey: requestID)
            }

            do {
                let comment = name.replacingOccurrences(of: " ", with: "_")
                let key = try await keyGenerator.generate(type: type, comment: comment)
                guard !Task.isCancelled else { return }
                let entry = try keyLibrary.storeSSHKeyEntry(
                    name: name,
                    privateKey: key.privateKey,
                    passphrase: normalizedPassphrase(passphrase),
                    keyType: key.keyType,
                    publicKey: key.publicKey
                )
                loadKeys()
                errorMessage = nil
                onSaved?(entry)
            } catch {
                guard !Task.isCancelled else { return }
                let message = String(format: String(localized: "Failed to generate key: %@"), error.localizedDescription)
                errorMessage = message
                onFailed?(message)
            }
        }

        generationTasks[requestID] = task
        return requestID
    }

    func waitForGenerationTask(_ requestID: UUID) async {
        await generationTasks[requestID]?.value
    }

    private func normalizedPassphrase(_ passphrase: String?) -> String? {
        guard let passphrase, !passphrase.isEmpty else {
            return nil
        }
        return passphrase
    }
}
