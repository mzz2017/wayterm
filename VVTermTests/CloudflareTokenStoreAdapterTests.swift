import Foundation
import Testing
@testable import VVTerm

// Test Context:
// These tests protect Cloudflare OAuth token persistence. OAuth tokens are
// credential secrets: they may use iCloud Keychain sync, but must not be
// governed by the CloudKit metadata sync toggle. Update these tests only if
// VVTerm intentionally changes the credential storage policy or token key
// namespace.
@Suite(.serialized)
struct CloudflareTokenStoreAdapterTests {
    @Test
    func writesOAuthTokensWithICloudKeychainPolicyWhenCloudKitSyncIsDisabled() async throws {
        let previousSyncSetting = UserDefaults.standard.object(forKey: SyncSettings.enabledKey)
        UserDefaults.standard.set(false, forKey: SyncSettings.enabledKey)
        defer {
            if let previousSyncSetting {
                UserDefaults.standard.set(previousSyncSetting, forKey: SyncSettings.enabledKey)
            } else {
                UserDefaults.standard.removeObject(forKey: SyncSettings.enabledKey)
            }
        }

        let store = RecordingCloudflareTokenKeychainStore()
        let adapter = CloudflareTokenStoreAdapter(
            readStoredToken: { try store.getString($0) },
            writeStoredToken: { token, key, iCloudSync in
                try store.setString(token, forKey: key, iCloudSync: iCloudSync)
            },
            removeStoredToken: { try store.delete($0) }
        )

        // Given CloudKit metadata sync is disabled.
        #expect(SyncSettings.isEnabled == false)

        // When an OAuth token is written.
        try await adapter.writeToken("oauth-secret", for: "team.example.com")

        // Then the token is stored under the OAuth namespace and still uses
        // the credential Keychain sync policy, independent of CloudKit.
        let write = try #require(store.setCalls.first)
        #expect(write.key == "oauth.team.example.com")
        #expect(write.data == Data("oauth-secret".utf8))
        #expect(
            write.iCloudSync,
            "Cloudflare OAuth token writes must remain iCloud Keychain-capable when CloudKit metadata sync is disabled."
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
