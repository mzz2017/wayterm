import Foundation

private enum ServerLocalDataStoreKeys {
    static let servers = CloudKitSyncConstants.serverStorageKey
    static let workspaces = CloudKitSyncConstants.workspaceStorageKey
    static let didBootstrapDefaultWorkspace = CloudKitSyncConstants.didBootstrapDefaultWorkspaceKey
    static let pendingBootstrapWorkspaceID = CloudKitSyncConstants.pendingBootstrapWorkspaceIDKey
    static let hasSeenWelcome = "hasSeenWelcome"
}

@MainActor
final class UserDefaultsServerLocalDataStore: ServerLocalDataStoring {
    private let defaults: UserDefaults
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        defaults: UserDefaults = .standard,
        encoder: JSONEncoder = JSONEncoder(),
        decoder: JSONDecoder = JSONDecoder()
    ) {
        self.defaults = defaults
        self.encoder = encoder
        self.decoder = decoder
    }

    func loadServers() -> [Server]? {
        guard let data = defaults.data(forKey: ServerLocalDataStoreKeys.servers) else {
            return nil
        }
        return try? decoder.decode([Server].self, from: data)
    }

    func loadWorkspaces() -> [Workspace]? {
        guard let data = defaults.data(forKey: ServerLocalDataStoreKeys.workspaces) else {
            return nil
        }
        return try? decoder.decode([Workspace].self, from: data)
    }

    func storeServers(_ servers: [Server]) {
        guard let data = try? encoder.encode(servers) else {
            return
        }
        defaults.set(data, forKey: ServerLocalDataStoreKeys.servers)
    }

    func storeWorkspaces(_ workspaces: [Workspace]) {
        guard let data = try? encoder.encode(workspaces) else {
            return
        }
        defaults.set(data, forKey: ServerLocalDataStoreKeys.workspaces)
    }

    var didBootstrapDefaultWorkspace: Bool {
        get { defaults.bool(forKey: ServerLocalDataStoreKeys.didBootstrapDefaultWorkspace) }
        set { defaults.set(newValue, forKey: ServerLocalDataStoreKeys.didBootstrapDefaultWorkspace) }
    }

    var hasSeenWelcome: Bool {
        defaults.bool(forKey: ServerLocalDataStoreKeys.hasSeenWelcome)
    }

    var pendingBootstrapWorkspaceID: UUID? {
        get {
            guard let rawValue = defaults.string(forKey: ServerLocalDataStoreKeys.pendingBootstrapWorkspaceID) else {
                return nil
            }
            return UUID(uuidString: rawValue)
        }
        set {
            if let newValue {
                defaults.set(newValue.uuidString, forKey: ServerLocalDataStoreKeys.pendingBootstrapWorkspaceID)
            } else {
                defaults.removeObject(forKey: ServerLocalDataStoreKeys.pendingBootstrapWorkspaceID)
            }
        }
    }

    func clearServerAndWorkspaceStorage() {
        defaults.removeObject(forKey: ServerLocalDataStoreKeys.servers)
        defaults.removeObject(forKey: ServerLocalDataStoreKeys.workspaces)
    }
}
