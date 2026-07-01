import Foundation
import Security
import Testing
@testable import Waterm

// Test Context:
// These tests protect the real KeychainStore write path behind credential and
// Cloudflare token persistence. When Waterm sync is disabled, rewriting a
// previously synced secret must migrate it to a device-local Keychain item
// instead of updating the old synchronizable item in place.
@Suite(.serialized)
struct KeychainStoreSyncMigrationTests {
    @Test
    func realKeychainRewriteSyncedItemAsDeviceLocalDeletesSyncedVariant() throws {
        let service = "app.vivy.waterm.tests.\(UUID().uuidString)"
        let account = "server.example.password"
        let store = KeychainStore(service: service)
        defer { try? store.delete(account) }

        try store.set(Data("old-synced-secret".utf8), forKey: account, iCloudSync: true)

        // Given the real Keychain contains a synchronizable secret.
        #expect(try realKeychainData(
            service: service,
            account: account,
            synchronizable: true
        ) == Data("old-synced-secret".utf8))

        // When the same key is rewritten after cross-device sync is disabled.
        try store.set(Data("new-local-secret".utf8), forKey: account, iCloudSync: false)

        // Then the real Keychain keeps only the device-local variant.
        #expect(try realKeychainData(
            service: service,
            account: account,
            synchronizable: false
        ) == Data("new-local-secret".utf8))
        #expect(try realKeychainData(
            service: service,
            account: account,
            synchronizable: true
        ) == nil)
    }

    @Test
    func rewritingSyncedItemAsDeviceLocalDeletesSyncedVariant() throws {
        let client = RecordingSecItemClient()
        let store = KeychainStore(service: "app.vivy.waterm.tests", secItemClient: client)
        try client.seed(
            service: "app.vivy.waterm.tests",
            account: "server.example.password",
            synchronizable: true,
            data: Data("old-synced-secret".utf8)
        )

        // Given a secret already exists as an iCloud Keychain item.
        #expect(try client.data(
            service: "app.vivy.waterm.tests",
            account: "server.example.password",
            synchronizable: true
        ) == Data("old-synced-secret".utf8))

        // When the same key is rewritten after cross-device sync is disabled.
        try store.set(
            Data("new-local-secret".utf8),
            forKey: "server.example.password",
            iCloudSync: false
        )

        // Then KeychainStore writes a device-local item and removes the synced
        // variant, so the old synchronizable item cannot continue syncing.
        #expect(try client.data(
            service: "app.vivy.waterm.tests",
            account: "server.example.password",
            synchronizable: false
        ) == Data("new-local-secret".utf8))
        #expect(try client.data(
            service: "app.vivy.waterm.tests",
            account: "server.example.password",
            synchronizable: true
        ) == nil)
        #expect(client.updateCalls.allSatisfy { $0.synchronizable != nil })
        #expect(
            !client.updateCalls.contains { $0.usedSynchronizableAny },
            "KeychainStore must not update with kSecAttrSynchronizableAny because that can mutate the old sync class in place."
        )
    }

    @Test
    func migrateAllSynchronizableItemsForServiceToDeviceLocal() throws {
        let client = RecordingSecItemClient()
        let service = "app.vivy.waterm.tests"
        let store = KeychainStore(service: service, secItemClient: client)
        try client.seed(
            service: service,
            account: "server.one.password",
            synchronizable: true,
            data: Data("one".utf8)
        )
        try client.seed(
            service: service,
            account: "oauth.team.example",
            synchronizable: true,
            data: Data("oauth".utf8)
        )
        try client.seed(
            service: "app.vivy.waterm.other",
            account: "server.two.password",
            synchronizable: true,
            data: Data("other".utf8)
        )

        // Given a Keychain service has existing iCloud Keychain secrets.

        // When sync is disabled and the service is migrated to device-local
        // storage.
        try store.migrateAllItems(toICloudSync: false)

        // Then every secret in that service is rewritten to the device-local
        // class, and unrelated Keychain services are untouched.
        #expect(try client.data(service: service, account: "server.one.password", synchronizable: false) == Data("one".utf8))
        #expect(try client.data(service: service, account: "server.one.password", synchronizable: true) == nil)
        #expect(try client.data(service: service, account: "oauth.team.example", synchronizable: false) == Data("oauth".utf8))
        #expect(try client.data(service: service, account: "oauth.team.example", synchronizable: true) == nil)
        #expect(try client.data(service: "app.vivy.waterm.other", account: "server.two.password", synchronizable: true) == Data("other".utf8))
    }

    private func realKeychainData(
        service: String,
        account: String,
        synchronizable: Bool
    ) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: kCFBooleanTrue as Any,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecAttrSynchronizable as String: (synchronizable ? kCFBooleanTrue : kCFBooleanFalse) as Any
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status != errSecItemNotFound else {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainError.unhandled(status)
        }
        return item as? Data
    }
}

private final class RecordingSecItemClient: SecItemClienting, @unchecked Sendable {
    private var items: [ItemKey: Data] = [:]
    private(set) var updateCalls: [UpdateCall] = []

    func seed(service: String, account: String, synchronizable: Bool, data: Data) throws {
        items[ItemKey(service: service, account: account, synchronizable: synchronizable)] = data
    }

    func data(service: String, account: String, synchronizable: Bool) throws -> Data? {
        items[ItemKey(service: service, account: account, synchronizable: synchronizable)]
    }

    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        guard let key = itemKey(from: query) else {
            return errSecParam
        }
        updateCalls.append(UpdateCall(synchronizable: key.synchronizable))
        guard items[key] != nil else {
            return errSecItemNotFound
        }
        if let data = attributes[kSecValueData as String] as? Data {
            items[key] = data
        }
        return errSecSuccess
    }

    func add(_ attributes: [String: Any]) -> OSStatus {
        guard let key = itemKey(from: attributes),
              let data = attributes[kSecValueData as String] as? Data else {
            return errSecParam
        }
        guard items[key] == nil else {
            return errSecDuplicateItem
        }
        items[key] = data
        return errSecSuccess
    }

    func copyMatching(_ query: [String: Any]) -> (OSStatus, CFTypeRef?) {
        if let matchLimit = query[kSecMatchLimit as String],
           CFEqual(matchLimit as CFTypeRef, kSecMatchLimitAll),
           let service = query[kSecAttrService as String] as? String,
           let synchronizableValue = query[kSecAttrSynchronizable as String],
           let synchronizable = boolValue(from: synchronizableValue) {
            let results: [[String: Any]] = items.compactMap { key, data in
                guard key.service == service, key.synchronizable == synchronizable else {
                    return nil
                }
                return [
                    kSecAttrService as String: key.service,
                    kSecAttrAccount as String: key.account,
                    kSecAttrSynchronizable as String: (key.synchronizable ? kCFBooleanTrue : kCFBooleanFalse) as Any,
                    kSecValueData as String: data
                ]
            }
            return results.isEmpty ? (errSecItemNotFound, nil) : (errSecSuccess, results as CFArray)
        }

        if let synchronizable = query[kSecAttrSynchronizable as String],
           isSynchronizableAny(synchronizable) {
            guard let service = query[kSecAttrService as String] as? String,
                  let account = query[kSecAttrAccount as String] as? String else {
                return (errSecParam, nil)
            }
            let syncedKey = ItemKey(service: service, account: account, synchronizable: true)
            let localKey = ItemKey(service: service, account: account, synchronizable: false)
            if let data = items[syncedKey] ?? items[localKey] {
                return (errSecSuccess, data as CFData)
            }
            return (errSecItemNotFound, nil)
        }

        guard let key = itemKey(from: query),
              let data = items[key] else {
            return (errSecItemNotFound, nil)
        }
        return (errSecSuccess, data as CFData)
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        if let synchronizable = query[kSecAttrSynchronizable as String],
           isSynchronizableAny(synchronizable) {
            guard let service = query[kSecAttrService as String] as? String,
                  let account = query[kSecAttrAccount as String] as? String else {
                return errSecParam
            }
            let removedSynced = items.removeValue(
                forKey: ItemKey(service: service, account: account, synchronizable: true)
            ) != nil
            let removedLocal = items.removeValue(
                forKey: ItemKey(service: service, account: account, synchronizable: false)
            ) != nil
            return removedSynced || removedLocal ? errSecSuccess : errSecItemNotFound
        }

        guard let key = itemKey(from: query) else {
            return errSecParam
        }
        return items.removeValue(forKey: key) == nil ? errSecItemNotFound : errSecSuccess
    }

    private func itemKey(from dictionary: [String: Any]) -> ItemKey? {
        guard let service = dictionary[kSecAttrService as String] as? String,
              let account = dictionary[kSecAttrAccount as String] as? String,
              let synchronizableValue = dictionary[kSecAttrSynchronizable as String],
              let synchronizable = boolValue(from: synchronizableValue) else {
            return nil
        }
        return ItemKey(service: service, account: account, synchronizable: synchronizable)
    }

    private func boolValue(from value: Any) -> Bool? {
        if let bool = value as? Bool {
            return bool
        }
        guard CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID() else {
            return nil
        }
        return CFBooleanGetValue((value as! CFBoolean))
    }

    private func isSynchronizableAny(_ value: Any) -> Bool {
        CFEqual(value as CFTypeRef, kSecAttrSynchronizableAny)
    }

    struct UpdateCall: Equatable {
        let synchronizable: Bool?

        var usedSynchronizableAny: Bool {
            synchronizable == nil
        }
    }

    private struct ItemKey: Hashable {
        let service: String
        let account: String
        let synchronizable: Bool
    }
}
