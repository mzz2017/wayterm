//
//  KeychainStore.swift
//  Waterm
//
//  Keychain wrapper for storing credentials with optional iCloud sync
//

import Foundation
import Security

protocol KeychainStoring: Sendable {
    func set(_ data: Data, forKey key: String, iCloudSync: Bool) throws
    func get(_ key: String) throws -> Data?
    func delete(_ key: String) throws
}

struct KeychainMigratedItem: Equatable, Sendable {
    let key: String
    let data: Data
    let sourceICloudSync: Bool
}

nonisolated enum KeychainSyncPolicy {
    // Waterm's sync setting is the cross-device total control: when CloudKit
    // sync is disabled, credential secrets must stay device-local too.
    static var usesICloudKeychainSync: Bool { SyncSettings.isEnabled }
}

final class KeychainStore: @unchecked Sendable {
    private let service: String
    private let secItemClient: any SecItemClienting

    nonisolated init(service: String) {
        self.service = service
        self.secItemClient = SecuritySecItemClient()
    }

    nonisolated init(service: String, secItemClient: any SecItemClienting) {
        self.service = service
        self.secItemClient = secItemClient
    }

    // MARK: - Data Operations

    nonisolated func set(_ data: Data, forKey key: String, iCloudSync: Bool = false) throws {
        let desiredQuery = synchronizableQuery(forKey: key, iCloudSync: iCloudSync)
        var attributes = desiredQuery
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = iCloudSync
            ? kSecAttrAccessibleAfterFirstUnlock
            : kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        var updateAttributes = attributes
        updateAttributes.removeValue(forKey: kSecClass as String)
        updateAttributes.removeValue(forKey: kSecAttrService as String)
        updateAttributes.removeValue(forKey: kSecAttrAccount as String)
        updateAttributes.removeValue(forKey: kSecAttrSynchronizable as String)

        let updateStatus = secItemClient.update(desiredQuery, attributes: updateAttributes)
        if updateStatus == errSecSuccess {
            try deleteSynchronizableVariant(forKey: key, iCloudSync: !iCloudSync)
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainError.unhandled(updateStatus)
        }

        let addStatus = secItemClient.add(attributes)
        if addStatus == errSecDuplicateItem {
            let retryStatus = secItemClient.update(desiredQuery, attributes: updateAttributes)
            guard retryStatus == errSecSuccess else {
                throw KeychainError.unhandled(retryStatus)
            }
        } else if addStatus != errSecSuccess {
            throw KeychainError.unhandled(addStatus)
        }
        try deleteSynchronizableVariant(forKey: key, iCloudSync: !iCloudSync)
    }

    nonisolated func get(_ key: String) throws -> Data? {
        // First try with iCloud sync (kSecAttrSynchronizable = true)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: kCFBooleanTrue as Any,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny  // Search both synced and non-synced
        ]

        let (status, item) = secItemClient.copyMatching(query)

        guard status != errSecItemNotFound else {
            return nil
        }

        guard status == errSecSuccess else {
            throw KeychainError.unhandled(status)
        }

        return item as? Data
    }

    nonisolated func delete(_ key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny  // Delete both synced and non-synced
        ]
        let status = secItemClient.delete(query)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unhandled(status)
        }
    }

    @discardableResult
    nonisolated func migrateAllItems(toICloudSync iCloudSync: Bool) throws -> [KeychainMigratedItem] {
        let sourceICloudSync = !iCloudSync
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: (sourceICloudSync ? kCFBooleanTrue : kCFBooleanFalse) as Any,
            kSecReturnAttributes as String: kCFBooleanTrue as Any,
            kSecReturnData as String: kCFBooleanTrue as Any,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]

        let (status, item) = secItemClient.copyMatching(query)
        guard status != errSecItemNotFound else {
            return []
        }
        guard status == errSecSuccess else {
            throw KeychainError.unhandled(status)
        }

        let items: [[String: Any]]
        if let itemArray = item as? [[String: Any]] {
            items = itemArray
        } else if let singleItem = item as? [String: Any] {
            items = [singleItem]
        } else {
            throw KeychainError.decodingFailed
        }

        var migratedItems: [KeychainMigratedItem] = []
        do {
            for item in items {
                guard let key = item[kSecAttrAccount as String] as? String,
                      let data = item[kSecValueData as String] as? Data else {
                    throw KeychainError.decodingFailed
                }
                try set(data, forKey: key, iCloudSync: iCloudSync)
                migratedItems.append(KeychainMigratedItem(
                    key: key,
                    data: data,
                    sourceICloudSync: sourceICloudSync
                ))
            }
        } catch {
            try? restoreMigratedItems(migratedItems)
            throw error
        }

        return migratedItems
    }

    nonisolated func restoreMigratedItems(_ items: [KeychainMigratedItem]) throws {
        for item in items.reversed() {
            try set(item.data, forKey: item.key, iCloudSync: item.sourceICloudSync)
        }
    }

    private nonisolated func baseQuery(forKey key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
    }

    private nonisolated func synchronizableQuery(forKey key: String, iCloudSync: Bool) -> [String: Any] {
        var query = baseQuery(forKey: key)
        query[kSecAttrSynchronizable as String] = (iCloudSync ? kCFBooleanTrue : kCFBooleanFalse) as Any
        return query
    }

    private nonisolated func deleteSynchronizableVariant(forKey key: String, iCloudSync: Bool) throws {
        let status = secItemClient.delete(synchronizableQuery(forKey: key, iCloudSync: iCloudSync))
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unhandled(status)
        }
    }

    // MARK: - String Convenience

    nonisolated func setString(_ value: String, forKey key: String, iCloudSync: Bool = false) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.encodingFailed
        }
        try set(data, forKey: key, iCloudSync: iCloudSync)
    }

    nonisolated func getString(_ key: String) throws -> String? {
        guard let data = try get(key) else {
            return nil
        }
        guard let string = String(data: data, encoding: .utf8) else {
            throw KeychainError.decodingFailed
        }
        return string
    }
}

extension KeychainStore: KeychainStoring {}

protocol SecItemClienting: Sendable {
    nonisolated func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus
    nonisolated func add(_ attributes: [String: Any]) -> OSStatus
    nonisolated func copyMatching(_ query: [String: Any]) -> (OSStatus, CFTypeRef?)
    nonisolated func delete(_ query: [String: Any]) -> OSStatus
}

private nonisolated struct SecuritySecItemClient: SecItemClienting {
    nonisolated func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }

    nonisolated func add(_ attributes: [String: Any]) -> OSStatus {
        SecItemAdd(attributes as CFDictionary, nil)
    }

    nonisolated func copyMatching(_ query: [String: Any]) -> (OSStatus, CFTypeRef?) {
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        return (status, item)
    }

    nonisolated func delete(_ query: [String: Any]) -> OSStatus {
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Keychain Error

enum KeychainError: LocalizedError {
    case unhandled(OSStatus)
    case encodingFailed
    case decodingFailed
    case itemNotFound

    var errorDescription: String? {
        switch self {
        case .unhandled(let status):
            return "Keychain error: \(status)"
        case .encodingFailed:
            return "Failed to encode data for keychain"
        case .decodingFailed:
            return "Failed to decode data from keychain"
        case .itemNotFound:
            return "Item not found in keychain"
        }
    }
}
