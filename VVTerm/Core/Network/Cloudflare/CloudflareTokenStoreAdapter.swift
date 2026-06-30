import Foundation
import Cloudflared

actor CloudflareTokenStoreAdapter: TokenStore {
    private let readStoredToken: @Sendable (String) throws -> String?
    private let writeStoredToken: @Sendable (String, String, Bool) throws -> Void
    private let removeStoredToken: @Sendable (String) throws -> Void

    init(store: KeychainStore = KeychainStore(service: "app.vivy.vvterm.cloudflare.tokens")) {
        self.init(
            readStoredToken: { try store.getString($0) },
            writeStoredToken: { token, key, iCloudSync in
                try store.setString(token, forKey: key, iCloudSync: iCloudSync)
            },
            removeStoredToken: { try store.delete($0) }
        )
    }

    init(
        readStoredToken: @escaping @Sendable (String) throws -> String?,
        writeStoredToken: @escaping @Sendable (String, String, Bool) throws -> Void,
        removeStoredToken: @escaping @Sendable (String) throws -> Void
    ) {
        self.readStoredToken = readStoredToken
        self.writeStoredToken = writeStoredToken
        self.removeStoredToken = removeStoredToken
    }

    func readToken(for key: String) async throws -> String? {
        try readStoredToken(namespacedKey(for: key))
    }

    func writeToken(_ token: String, for key: String) async throws {
        try writeStoredToken(
            token,
            namespacedKey(for: key),
            KeychainSyncPolicy.usesICloudKeychainSync
        )
    }

    func removeToken(for key: String) async throws {
        try removeStoredToken(namespacedKey(for: key))
    }

    private func namespacedKey(for key: String) -> String {
        "oauth.\(key)"
    }
}
