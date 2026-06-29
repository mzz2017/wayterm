import Foundation

nonisolated struct RemoteFileBrowserPersistedStateStore {
    private let persistenceKey: String
    private let legacyPersistenceKey: String
    private let userDefaults: UserDefaults

    init(
        persistenceKey: String = "remoteFileBrowserState.v2",
        legacyPersistenceKey: String = "remoteFileBrowserState.v1",
        userDefaults: UserDefaults = .standard
    ) {
        self.persistenceKey = persistenceKey
        self.legacyPersistenceKey = legacyPersistenceKey
        self.userDefaults = userDefaults
    }

    func load() throws -> [String: RemoteFileBrowserPersistedState] {
        removeLegacyStateIfNeeded()

        guard let data = userDefaults.data(forKey: persistenceKey) else {
            return [:]
        }
        return try JSONDecoder().decode([String: RemoteFileBrowserPersistedState].self, from: data)
    }

    func save(_ states: [String: RemoteFileBrowserPersistedState]) throws {
        let data = try JSONEncoder().encode(states)
        userDefaults.set(data, forKey: persistenceKey)
    }

    private func removeLegacyStateIfNeeded() {
        guard userDefaults.object(forKey: legacyPersistenceKey) != nil else { return }
        userDefaults.removeObject(forKey: legacyPersistenceKey)
    }
}
