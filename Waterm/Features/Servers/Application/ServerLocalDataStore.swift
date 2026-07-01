import Foundation

@MainActor
protocol ServerLocalDataStoring: AnyObject {
    func loadServers() -> [Server]?
    func loadWorkspaces() -> [Workspace]?
    func storeServers(_ servers: [Server])
    func storeWorkspaces(_ workspaces: [Workspace])
    var didBootstrapDefaultWorkspace: Bool { get set }
    var hasSeenWelcome: Bool { get }
    var pendingBootstrapWorkspaceID: UUID? { get set }
    func clearServerAndWorkspaceStorage()
}

#if DEBUG
@MainActor
final class InMemoryServerLocalDataStore: ServerLocalDataStoring {
    private var storedServers: [Server]?
    private var storedWorkspaces: [Workspace]?
    var didBootstrapDefaultWorkspace = false
    var hasSeenWelcome = false
    var pendingBootstrapWorkspaceID: UUID?

    init(
        servers: [Server]? = nil,
        workspaces: [Workspace]? = nil,
        didBootstrapDefaultWorkspace: Bool = false,
        hasSeenWelcome: Bool = false,
        pendingBootstrapWorkspaceID: UUID? = nil
    ) {
        self.storedServers = servers
        self.storedWorkspaces = workspaces
        self.didBootstrapDefaultWorkspace = didBootstrapDefaultWorkspace
        self.hasSeenWelcome = hasSeenWelcome
        self.pendingBootstrapWorkspaceID = pendingBootstrapWorkspaceID
    }

    func loadServers() -> [Server]? {
        storedServers
    }

    func loadWorkspaces() -> [Workspace]? {
        storedWorkspaces
    }

    func storeServers(_ servers: [Server]) {
        storedServers = servers
    }

    func storeWorkspaces(_ workspaces: [Workspace]) {
        storedWorkspaces = workspaces
    }

    func clearServerAndWorkspaceStorage() {
        storedServers = nil
        storedWorkspaces = nil
    }
}
#endif
