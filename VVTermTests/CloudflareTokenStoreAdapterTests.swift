import Foundation
import Testing
@testable import VVTerm

// Test Context:
// These tests protect Cloudflare OAuth token persistence. OAuth tokens are
// credential secrets governed by VVTerm's sync setting. When the user disables
// CloudKit sync, token writes must stay device-local instead of uploading to
// iCloud Keychain. Update these tests only if VVTerm intentionally splits
// credential sync from the app-wide sync toggle or changes the token key
// namespace.
@Suite(.serialized)
struct CloudflareTokenStoreAdapterTests {
    @Test
    func writesOAuthTokensDeviceLocalWhenSyncPolicyIsDisabled() async throws {
        let store = RecordingCloudflareTokenKeychainStore()
        let adapter = CloudflareTokenStoreAdapter(
            readStoredToken: { try store.getString($0) },
            writeStoredToken: { token, key, iCloudSync in
                try store.setString(token, forKey: key, iCloudSync: iCloudSync)
            },
            removeStoredToken: { try store.delete($0) },
            usesICloudKeychainSync: { false }
        )

        // Given VVTerm's cross-device sync policy is disabled.

        // When an OAuth token is written.
        try await adapter.writeToken("oauth-secret", for: "team.example.com")

        // Then the token is stored under the OAuth namespace and remains
        // device-local because the sync setting is the cross-device total
        // control.
        let write = try #require(store.setCalls.first)
        #expect(write.key == "oauth.team.example.com")
        #expect(write.data == Data("oauth-secret".utf8))
        #expect(
            write.iCloudSync == false,
            "Cloudflare OAuth token writes must not use iCloud Keychain when CloudKit sync is disabled."
        )
    }

    @Test
    func writesOAuthTokensWithICloudKeychainWhenSyncPolicyIsEnabled() async throws {
        let store = RecordingCloudflareTokenKeychainStore()
        let adapter = CloudflareTokenStoreAdapter(
            readStoredToken: { try store.getString($0) },
            writeStoredToken: { token, key, iCloudSync in
                try store.setString(token, forKey: key, iCloudSync: iCloudSync)
            },
            removeStoredToken: { try store.delete($0) },
            usesICloudKeychainSync: { true }
        )

        // Given VVTerm's cross-device sync policy is enabled.

        // When an OAuth token is written.
        try await adapter.writeToken("oauth-secret", for: "team.example.com")

        // Then the token write remains iCloud Keychain-capable.
        let write = try #require(store.setCalls.first)
        #expect(write.key == "oauth.team.example.com")
        #expect(
            write.iCloudSync,
            "Cloudflare OAuth token writes should use iCloud Keychain when sync is enabled."
        )
    }
}

private final class RecordingCloudflareTokenKeychainStore: @unchecked Sendable {
    private(set) var setCalls: [SetCall] = []
    private(set) var storedData: [String: Data] = [:]
    private(set) var deletedKeys: [String] = []

    func set(_ data: Data, forKey key: String, iCloudSync: Bool) throws {
        setCalls.append(SetCall(key: key, data: data, iCloudSync: iCloudSync))
        storedData[key] = data
    }

    func get(_ key: String) throws -> Data? {
        storedData[key]
    }

    func delete(_ key: String) throws {
        deletedKeys.append(key)
        storedData.removeValue(forKey: key)
    }

    func setString(_ value: String, forKey key: String, iCloudSync: Bool) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.encodingFailed
        }
        try set(data, forKey: key, iCloudSync: iCloudSync)
    }

    func getString(_ key: String) throws -> String? {
        guard let data = try get(key) else {
            return nil
        }
        guard let string = String(data: data, encoding: .utf8) else {
            throw KeychainError.decodingFailed
        }
        return string
    }

    struct SetCall: Equatable {
        let key: String
        let data: Data
        let iCloudSync: Bool
    }
}
