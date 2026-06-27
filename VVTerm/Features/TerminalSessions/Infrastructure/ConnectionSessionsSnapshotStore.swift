//
//  ConnectionSessionsSnapshotStore.swift
//  VVTerm
//
//  UserDefaults persistence for connection session snapshots.
//

import Foundation

struct ConnectionSessionsSnapshotStore {
    private let key: String
    private let userDefaults: UserDefaults

    init(
        key: String = "connectionSessionsSnapshot.v1",
        userDefaults: UserDefaults = .standard
    ) {
        self.key = key
        self.userDefaults = userDefaults
    }

    func save(_ snapshot: ConnectionSessionsSnapshot) throws {
        let data = try JSONEncoder().encode(snapshot)
        userDefaults.set(data, forKey: key)
    }

    func load() throws -> ConnectionSessionsSnapshot? {
        guard let data = userDefaults.data(forKey: key) else { return nil }
        return try JSONDecoder().decode(ConnectionSessionsSnapshot.self, from: data)
    }

    func remove() {
        userDefaults.removeObject(forKey: key)
    }
}
