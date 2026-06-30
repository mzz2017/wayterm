import Foundation
import CloudKit

enum PendingCloudKitEntity: String, Codable {
    case server
    case workspace
    case terminalTheme
    case terminalThemePreference
    case terminalAccessoryProfile
}

enum PendingCloudKitOperation: String, Codable {
    case upsert
    case delete
}

struct PendingCloudKitMutation: Codable, Identifiable {
    let id: UUID
    let entity: PendingCloudKitEntity
    let operation: PendingCloudKitOperation
    let entityKey: String
    let payload: Data?
    let createdAt: Date
    var retryCount: Int
    var nextRetryAt: Date?
    var lastErrorCode: String?
    var lastErrorDescription: String?

    static func upsert(
        entity: PendingCloudKitEntity,
        entityKey: String,
        payload: Data?
    ) -> PendingCloudKitMutation {
        PendingCloudKitMutation(
            id: UUID(),
            entity: entity,
            operation: .upsert,
            entityKey: entityKey,
            payload: payload,
            createdAt: Date(),
            retryCount: 0,
            nextRetryAt: nil,
            lastErrorCode: nil,
            lastErrorDescription: nil
        )
    }

    static func delete(
        entity: PendingCloudKitEntity,
        entityKey: String,
        payload: Data? = nil
    ) -> PendingCloudKitMutation {
        PendingCloudKitMutation(
            id: UUID(),
            entity: entity,
            operation: .delete,
            entityKey: entityKey,
            payload: payload,
            createdAt: Date(),
            retryCount: 0,
            nextRetryAt: nil,
            lastErrorCode: nil,
            lastErrorDescription: nil
        )
    }

    func decodedPayload<T: Decodable>(as type: T.Type = T.self) throws -> T? {
        guard let payload else { return nil }
        return try JSONDecoder().decode(type, from: payload)
    }

    static func encodedPayload<T: Encodable>(for value: T) throws -> Data {
        try JSONEncoder().encode(value)
    }

    var operationPriority: Int {
        switch operation {
        case .upsert: return 0
        case .delete: return 1
        }
    }

    var entityPriority: Int {
        switch entity {
        case .workspace: return 0
        case .server: return 1
        case .terminalTheme: return 2
        case .terminalThemePreference: return 3
        case .terminalAccessoryProfile: return 4
        }
    }

    var entityDescription: String {
        let kind: String
        switch entity {
        case .server: kind = "server"
        case .workspace: kind = "workspace"
        case .terminalTheme: kind = "terminal theme"
        case .terminalThemePreference: kind = "terminal theme preference"
        case .terminalAccessoryProfile: kind = "terminal accessory profile"
        }

        let op: String
        switch operation {
        case .upsert: op = "upsert"
        case .delete: op = "delete"
        }

        return "\(kind) \(op) \(entityKey)"
    }

    var drainPriority: Int {
        switch (entity, operation) {
        case (.workspace, .upsert): return 0
        case (.server, .upsert): return 1
        case (.terminalTheme, .upsert): return 2
        case (.terminalThemePreference, .upsert): return 3
        case (.terminalAccessoryProfile, .upsert): return 4
        case (.server, .delete): return 5
        case (.workspace, .delete): return 6
        case (.terminalTheme, .delete): return 7
        case (.terminalThemePreference, .delete): return 8
        case (.terminalAccessoryProfile, .delete): return 9
        }
    }

    func canAttempt(at date: Date) -> Bool {
        guard let nextRetryAt else { return true }
        return nextRetryAt <= date
    }

    func withFailure(error: Error) -> PendingCloudKitMutation {
        var copy = self
        copy.retryCount += 1
        copy.lastErrorDescription = error.localizedDescription
        copy.lastErrorCode = PendingCloudKitMutation.errorCodeString(for: error)
        let delay = min(pow(2.0, Double(max(0, copy.retryCount - 1))) * 30.0, 3600.0)
        copy.nextRetryAt = Date().addingTimeInterval(delay)
        return copy
    }

    static func errorCodeString(for error: Error) -> String? {
        if let ckError = error as? CKError {
            return String(describing: ckError.code)
        }
        if let localizedError = error as? LocalizedError, let description = localizedError.errorDescription {
            return description
        }
        return error.localizedDescription
    }
}

extension PendingCloudKitMutation {
    private enum CodingKeys: String, CodingKey {
        case id
        case entity
        case operation
        case entityKey
        case payload
        case createdAt
        case retryCount
        case nextRetryAt
        case lastErrorCode
        case lastErrorDescription
        case server
        case workspace
        case terminalTheme
        case terminalThemePreference
        case terminalAccessoryProfile
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        entity = try container.decode(PendingCloudKitEntity.self, forKey: .entity)
        operation = try container.decode(PendingCloudKitOperation.self, forKey: .operation)
        entityKey = try container.decode(String.self, forKey: .entityKey)
        payload = try container.decodeIfPresent(Data.self, forKey: .payload)
            ?? Self.legacyPayload(from: container)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        retryCount = try container.decode(Int.self, forKey: .retryCount)
        nextRetryAt = try container.decodeIfPresent(Date.self, forKey: .nextRetryAt)
        lastErrorCode = try container.decodeIfPresent(String.self, forKey: .lastErrorCode)
        lastErrorDescription = try container.decodeIfPresent(String.self, forKey: .lastErrorDescription)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(entity, forKey: .entity)
        try container.encode(operation, forKey: .operation)
        try container.encode(entityKey, forKey: .entityKey)
        try container.encodeIfPresent(payload, forKey: .payload)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(retryCount, forKey: .retryCount)
        try container.encodeIfPresent(nextRetryAt, forKey: .nextRetryAt)
        try container.encodeIfPresent(lastErrorCode, forKey: .lastErrorCode)
        try container.encodeIfPresent(lastErrorDescription, forKey: .lastErrorDescription)
    }

    private static func legacyPayload(from container: KeyedDecodingContainer<CodingKeys>) -> Data? {
        let legacyKeys: [CodingKeys] = [
            .server,
            .workspace,
            .terminalTheme,
            .terminalThemePreference,
            .terminalAccessoryProfile
        ]

        for key in legacyKeys {
            guard let value = try? container.decodeIfPresent(PendingCloudKitJSONValue.self, forKey: key) else {
                continue
            }
            return try? JSONEncoder().encode(value)
        }

        return nil
    }
}

private enum PendingCloudKitJSONValue: Codable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case object([String: PendingCloudKitJSONValue])
    case array([PendingCloudKitJSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([PendingCloudKitJSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: PendingCloudKitJSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported pending CloudKit JSON payload")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}

final class PendingCloudKitSyncQueue {
    private let storageKey: String
    private var items: [PendingCloudKitMutation]

    init(storageKey: String = CloudKitSyncConstants.pendingCloudKitSyncQueueStorageKey) {
        self.storageKey = storageKey
        self.items = []
        load()
    }

    func snapshot() -> [PendingCloudKitMutation] {
        items
    }

    func enqueue(_ mutation: PendingCloudKitMutation) {
        items.removeAll { $0.entity == mutation.entity && $0.entityKey == mutation.entityKey }
        items.append(mutation)
        persist()
    }

    func remove(_ mutationID: UUID) {
        items.removeAll { $0.id == mutationID }
        persist()
    }

    func removeAll() {
        items.removeAll()
        persist()
    }

    func removeAll(where shouldRemove: (PendingCloudKitMutation) -> Bool) {
        items.removeAll(where: shouldRemove)
        persist()
    }

    func canAttempt(_ mutation: PendingCloudKitMutation, at date: Date) -> Bool {
        mutation.canAttempt(at: date)
    }

    func recordFailure(for mutation: PendingCloudKitMutation, error: Error) {
        guard let index = items.firstIndex(where: { $0.id == mutation.id }) else {
            return
        }

        items[index] = items[index].withFailure(error: error)
        persist()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else {
            return
        }

        let decoder = JSONDecoder()
        if let decoded = try? decoder.decode([PendingCloudKitMutation].self, from: data) {
            items = decoded
            return
        }

        if let decoded = try? decoder.decode([LossyPendingCloudKitMutation].self, from: data) {
            items = decoded.compactMap(\.mutation)
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(items) else {
            return
        }

        UserDefaults.standard.set(data, forKey: storageKey)
    }
}

private struct LossyPendingCloudKitMutation: Decodable {
    let mutation: PendingCloudKitMutation?

    init(from decoder: Decoder) throws {
        mutation = try? PendingCloudKitMutation(from: decoder)
    }
}
