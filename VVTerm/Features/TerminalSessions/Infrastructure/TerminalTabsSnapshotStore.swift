//
//  TerminalTabsSnapshotStore.swift
//  VVTerm
//
//  UserDefaults persistence for terminal tab snapshots.
//

import Foundation

nonisolated struct TerminalTabsSnapshotStore {
    private let key: String
    private let userDefaults: UserDefaults

    init(
        key: String = "terminalTabsSnapshot.v1",
        userDefaults: UserDefaults = .standard
    ) {
        self.key = key
        self.userDefaults = userDefaults
    }

    func save(_ snapshot: TerminalTabsSnapshot) throws {
        let data = try JSONEncoder().encode(snapshot)
        userDefaults.set(data, forKey: key)
    }

    func load() throws -> TerminalTabsSnapshot? {
        guard let data = userDefaults.data(forKey: key) else { return nil }
        return try JSONDecoder().decode(TerminalTabsSnapshot.self, from: data)
    }

    func remove() {
        userDefaults.removeObject(forKey: key)
    }
}
