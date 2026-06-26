import Foundation

extension ServerManager {
    var canAddServer: Bool {
        ServerAccessPolicy.canAddServer(isPro: isProProvider(), servers: servers)
    }

    var canAddWorkspace: Bool {
        ServerAccessPolicy.canAddWorkspace(isPro: isProProvider(), workspaces: workspaces)
    }

    var canCreateCustomEnvironment: Bool {
        ServerAccessPolicy.canCreateCustomEnvironment(isPro: isProProvider())
    }

    /// Set of server IDs that are accessible on free tier (oldest N servers)
    var unlockedServerIds: Set<UUID> {
        ServerAccessPolicy.unlockedServerIds(isPro: isProProvider(), servers: servers)
    }

    /// Set of workspace IDs that are accessible on free tier (first N workspaces by order)
    var unlockedWorkspaceIds: Set<UUID> {
        ServerAccessPolicy.unlockedWorkspaceIds(isPro: isProProvider(), workspaces: workspaces)
    }

    /// Check if a specific server is locked (over free tier limit)
    func isServerLocked(_ server: Server) -> Bool {
        ServerAccessPolicy.isServerLocked(server, isPro: isProProvider(), servers: servers)
    }

    /// Check if a specific workspace is locked (over free tier limit)
    func isWorkspaceLocked(_ workspace: Workspace) -> Bool {
        ServerAccessPolicy.isWorkspaceLocked(workspace, isPro: isProProvider(), workspaces: workspaces)
    }

    /// Number of servers that are locked due to downgrade
    var lockedServersCount: Int {
        ServerAccessPolicy.lockedServersCount(isPro: isProProvider(), servers: servers)
    }

    /// Number of workspaces that are locked due to downgrade
    var lockedWorkspacesCount: Int {
        ServerAccessPolicy.lockedWorkspacesCount(isPro: isProProvider(), workspaces: workspaces)
    }

    /// Whether user has any locked items after downgrade
    var hasLockedItems: Bool {
        ServerAccessPolicy.hasLockedItems(
            isPro: isProProvider(),
            servers: servers,
            workspaces: workspaces
        )
    }

}
