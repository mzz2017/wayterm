import Foundation
import os.log

private enum ServerManagerPersistenceKeys {
    static let servers = CloudKitSyncConstants.serverStorageKey
    static let workspaces = CloudKitSyncConstants.workspaceStorageKey
    static let didBootstrapDefaultWorkspace = CloudKitSyncConstants.didBootstrapDefaultWorkspaceKey
    static let pendingBootstrapWorkspaceID = CloudKitSyncConstants.pendingBootstrapWorkspaceIDKey
    static let hasSeenWelcome = "hasSeenWelcome"
}

extension ServerManager {
    // MARK: - Local Storage

    func loadLocalData() {
        var shouldPersist = false

        if let decoded = loadStoredServers() {
            servers = decoded
            logger.info("Loaded \(decoded.count) servers from local storage")
        }

        if let decoded = loadStoredWorkspaces() {
            workspaces = decoded
            logger.info("Loaded \(decoded.count) workspaces from local storage")
        }

        shouldPersist = reconcilePendingBootstrapWorkspaceState() || shouldPersist

        if Self.shouldCreateBootstrapWorkspace(
            didBootstrapDefaultWorkspace: didBootstrapDefaultWorkspace,
            hasSeenWelcome: hasSeenWelcome,
            hasLocalWorkspaces: !workspaces.isEmpty
        ) {
            createBootstrapWorkspace()
            didBootstrapDefaultWorkspace = true
            shouldPersist = true
        }

        if shouldPersist {
            saveLocalData()
        }
    }

    func saveLocalData() {
        guard persistsLocalData else { return }

        storeServers(servers)
        storeWorkspaces(workspaces)
    }

    func loadStoredServers() -> [Server]? {
        guard let data = UserDefaults.standard.data(forKey: ServerManagerPersistenceKeys.servers) else {
            return nil
        }
        return try? JSONDecoder().decode([Server].self, from: data)
    }

    func loadStoredWorkspaces() -> [Workspace]? {
        guard let data = UserDefaults.standard.data(forKey: ServerManagerPersistenceKeys.workspaces) else {
            return nil
        }
        return try? JSONDecoder().decode([Workspace].self, from: data)
    }

    func storeServers(_ servers: [Server]) {
        guard let data = try? JSONEncoder().encode(servers) else {
            return
        }
        UserDefaults.standard.set(data, forKey: ServerManagerPersistenceKeys.servers)
    }

    func storeWorkspaces(_ workspaces: [Workspace]) {
        guard let data = try? JSONEncoder().encode(workspaces) else {
            return
        }
        UserDefaults.standard.set(data, forKey: ServerManagerPersistenceKeys.workspaces)
    }

    var didBootstrapDefaultWorkspace: Bool {
        get { UserDefaults.standard.bool(forKey: ServerManagerPersistenceKeys.didBootstrapDefaultWorkspace) }
        set { UserDefaults.standard.set(newValue, forKey: ServerManagerPersistenceKeys.didBootstrapDefaultWorkspace) }
    }

    var hasSeenWelcome: Bool {
        UserDefaults.standard.bool(forKey: ServerManagerPersistenceKeys.hasSeenWelcome)
    }

    var pendingBootstrapWorkspaceID: UUID? {
        get {
            guard let rawValue = UserDefaults.standard.string(forKey: ServerManagerPersistenceKeys.pendingBootstrapWorkspaceID) else {
                return nil
            }
            return UUID(uuidString: rawValue)
        }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue.uuidString, forKey: ServerManagerPersistenceKeys.pendingBootstrapWorkspaceID)
            } else {
                UserDefaults.standard.removeObject(forKey: ServerManagerPersistenceKeys.pendingBootstrapWorkspaceID)
            }
        }
    }

    var transientBootstrapWorkspaceID: UUID? {
        pendingBootstrapWorkspaceID
    }

    var shouldForceCloudKitFullFetchForBootstrap: Bool {
        pendingBootstrapWorkspaceID != nil
    }

    var localCacheContainsUserData: Bool {
        if !servers.isEmpty {
            return true
        }

        let effectiveWorkspaces = workspaces.filter { $0.id != transientBootstrapWorkspaceID }

        guard !effectiveWorkspaces.isEmpty else {
            return false
        }

        if effectiveWorkspaces.count > 1 {
            return true
        }

        guard let workspace = effectiveWorkspaces.first else {
            return false
        }

        return !isCanonicalDefaultWorkspace(workspace)
    }

    func createBootstrapWorkspace() {
        let workspace = createDefaultWorkspace()
        workspaces = [workspace]

        if isSyncEnabled {
            pendingBootstrapWorkspaceID = workspace.id
            logger.info("Created pending default workspace: \(workspace.name)")
        } else {
            pendingBootstrapWorkspaceID = nil
            logger.info("Created default workspace: \(workspace.name)")
        }
    }

    @discardableResult
    func reconcilePendingBootstrapWorkspaceState() -> Bool {
        guard let pendingBootstrapWorkspaceID else {
            return false
        }

        guard workspaces.contains(where: { $0.id == pendingBootstrapWorkspaceID }) else {
            self.pendingBootstrapWorkspaceID = nil
            return true
        }

        if servers.contains(where: { $0.workspaceId == pendingBootstrapWorkspaceID }) || workspaces.count > 1 {
            self.pendingBootstrapWorkspaceID = nil
            logger.info("Promoted pending bootstrap workspace \(pendingBootstrapWorkspaceID.uuidString) into regular local state")
            return true
        }

        return refreshPendingBootstrapWorkspaceLocalizationIfNeeded()
    }

    @discardableResult
    func refreshPendingBootstrapWorkspaceLocalizationIfNeeded() -> Bool {
        guard let pendingBootstrapWorkspaceID,
              let index = workspaces.firstIndex(where: { $0.id == pendingBootstrapWorkspaceID }) else {
            return false
        }

        let localizedName = AppLanguage.localizedString("My Servers")
        guard workspaces[index].name != localizedName,
              Self.isCanonicalDefaultWorkspaceCandidate(workspaces[index]) else {
            return false
        }

        workspaces[index].name = localizedName
        logger.info("Updated pending bootstrap workspace name to match selected app language")
        return true
    }

    func promotePendingBootstrapWorkspaceIfNeeded(for workspaceID: UUID, reason: String) {
        guard pendingBootstrapWorkspaceID == workspaceID else { return }
        pendingBootstrapWorkspaceID = nil
        logger.info("Promoted pending bootstrap workspace after \(reason)")
    }

    func resolvePendingBootstrapWorkspaceAgainstAuthoritativeFetch(_ changes: CloudKitChanges) {
        guard changes.isFullFetch,
              changes.workspaces.isEmpty,
              let pendingBootstrapWorkspaceID,
              let workspace = workspaces.first(where: { $0.id == pendingBootstrapWorkspaceID }) else {
            return
        }

        self.pendingBootstrapWorkspaceID = nil
        enqueuePendingWorkspaceUpsert(workspace)
        logger.info("Promoted pending bootstrap workspace after authoritative CloudKit fetch returned no workspaces")
    }

    func isCanonicalDefaultWorkspace(_ workspace: Workspace) -> Bool {
        Self.isCanonicalDefaultWorkspaceCandidate(workspace)
    }

    func createDefaultWorkspace() -> Workspace {
        Workspace(
            name: AppLanguage.localizedString("My Servers"),
            colorHex: "#007AFF",
            order: 0
        )
    }

    static func shouldCreateBootstrapWorkspace(
        didBootstrapDefaultWorkspace: Bool,
        hasSeenWelcome: Bool,
        hasLocalWorkspaces: Bool
    ) -> Bool {
        !(didBootstrapDefaultWorkspace || hasSeenWelcome) && !hasLocalWorkspaces
    }

    static func isCanonicalDefaultWorkspaceCandidate(_ workspace: Workspace) -> Bool {
        AppLanguage.localizedValues(for: "My Servers").contains(workspace.name) &&
            workspace.colorHex == "#007AFF" &&
            workspace.icon == nil &&
            workspace.order == 0 &&
            workspace.environments == ServerEnvironment.builtInEnvironments &&
            workspace.lastSelectedEnvironmentId == nil &&
            workspace.lastSelectedServerId == nil
    }

    /// Clear all local data and re-download from CloudKit.
    func clearLocalDataAndResync() async {
        logger.info("Clearing local data and re-syncing from CloudKit...")

        UserDefaults.standard.removeObject(forKey: ServerManagerPersistenceKeys.servers)
        UserDefaults.standard.removeObject(forKey: ServerManagerPersistenceKeys.workspaces)
        pendingBootstrapWorkspaceID = nil
        syncCoordinator.clearPendingMutations(for: [.server, .workspace])

        servers = []
        workspaces = []
        error = nil

        await loadData()

        logger.info("Clear and re-sync complete: \(self.workspaces.count) workspaces, \(self.servers.count) servers")
    }
}
