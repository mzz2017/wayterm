import Foundation

nonisolated enum ServerAccessPolicy {
    static func canAddServer(isPro: Bool, servers: [Server]) -> Bool {
        isPro || servers.count < FreeTierLimits.maxServers
    }

    static func canAddWorkspace(isPro: Bool, workspaces: [Workspace]) -> Bool {
        isPro || workspaces.count < FreeTierLimits.maxWorkspaces
    }

    static func canCreateCustomEnvironment(isPro: Bool) -> Bool {
        isPro
    }

    static func unlockedServerIds(isPro: Bool, servers: [Server]) -> Set<UUID> {
        if isPro { return Set(servers.map(\.id)) }
        let unlocked = serversSortedByCreation(servers).prefix(FreeTierLimits.maxServers)
        return Set(unlocked.map(\.id))
    }

    static func unlockedWorkspaceIds(isPro: Bool, workspaces: [Workspace]) -> Set<UUID> {
        if isPro { return Set(workspaces.map(\.id)) }
        let unlocked = workspacesSortedByOrder(workspaces).prefix(FreeTierLimits.maxWorkspaces)
        return Set(unlocked.map(\.id))
    }

    static func isServerLocked(_ server: Server, isPro: Bool, servers: [Server]) -> Bool {
        if isPro { return false }
        return !unlockedServerIds(isPro: isPro, servers: servers).contains(server.id)
    }

    static func isWorkspaceLocked(_ workspace: Workspace, isPro: Bool, workspaces: [Workspace]) -> Bool {
        if isPro { return false }
        return !unlockedWorkspaceIds(isPro: isPro, workspaces: workspaces).contains(workspace.id)
    }

    static func lockedServersCount(isPro: Bool, servers: [Server]) -> Int {
        if isPro { return 0 }
        return max(0, servers.count - FreeTierLimits.maxServers)
    }

    static func lockedWorkspacesCount(isPro: Bool, workspaces: [Workspace]) -> Int {
        if isPro { return 0 }
        return max(0, workspaces.count - FreeTierLimits.maxWorkspaces)
    }

    static func hasLockedItems(isPro: Bool, servers: [Server], workspaces: [Workspace]) -> Bool {
        lockedServersCount(isPro: isPro, servers: servers) > 0
            || lockedWorkspacesCount(isPro: isPro, workspaces: workspaces) > 0
    }

    static func moveDestinationIDs(
        isPro: Bool,
        server: Server,
        workspaces: [Workspace]
    ) -> Set<UUID> {
        ServerMoveSupport.allowedDestinationIDs(
            isPro: isPro,
            sourceWorkspaceId: server.workspaceId,
            workspacesInOrder: workspacesSortedByOrder(workspaces),
            unlockedWorkspaceIds: unlockedWorkspaceIds(isPro: isPro, workspaces: workspaces)
        )
    }

    static func workspacesSortedByOrder(_ workspaces: [Workspace]) -> [Workspace] {
        workspaces.sorted { $0.order < $1.order }
    }

    private static func serversSortedByCreation(_ servers: [Server]) -> [Server] {
        servers.sorted { $0.createdAt < $1.createdAt }
    }
}
