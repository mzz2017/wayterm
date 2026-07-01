import Foundation

struct RemoteFileTabsSnapshotStore {
    private let key: String
    private let userDefaults: UserDefaults

    init(
        key: String = "remoteFileTabsSnapshot.v1",
        userDefaults: UserDefaults = .standard
    ) {
        self.key = key
        self.userDefaults = userDefaults
    }

    func save(_ snapshot: RemoteFileTabSnapshot) throws {
        let data = try JSONEncoder().encode(snapshot)
        userDefaults.set(data, forKey: key)
    }

    func load() throws -> RemoteFileTabSnapshot? {
        guard let data = userDefaults.data(forKey: key) else { return nil }
        return try JSONDecoder().decode(RemoteFileTabSnapshot.self, from: data)
    }

    func remove() {
        userDefaults.removeObject(forKey: key)
    }
}
