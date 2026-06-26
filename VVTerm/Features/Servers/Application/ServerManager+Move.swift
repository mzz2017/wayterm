import Foundation

extension ServerManager {
    func assignmentWorkspaces(for server: Server?) -> [Workspace] {
        let workspacesSortedByOrder = ServerAccessPolicy.workspacesSortedByOrder(workspaces)

        if StoreManager.shared.isPro {
            return workspacesSortedByOrder
        }

        guard let server,
              let currentWorkspace = workspace(withId: server.workspaceId) else {
            return workspacesSortedByOrder.filter { unlockedWorkspaceIds.contains($0.id) }
        }

        let allowedDestinationIDs = moveDestinationIDs(for: server)
        return workspacesSortedByOrder.filter {
            $0.id == currentWorkspace.id || allowedDestinationIDs.contains($0.id)
        }
    }

    func moveDestinations(for server: Server) -> [Workspace] {
        let destinationIDs = moveDestinationIDs(for: server)
        return ServerAccessPolicy.workspacesSortedByOrder(workspaces).filter { destinationIDs.contains($0.id) }
    }

    func resolvedEnvironment(
        for server: Server,
        destination: Workspace,
        preferredEnvironment: ServerEnvironment? = nil
    ) -> ServerEnvironment {
        ServerMoveSupport.resolveEnvironment(
            currentEnvironment: server.environment,
            preferredEnvironment: preferredEnvironment,
            destination: destination
        )
    }

    func moveRequiresEnvironmentFallback(_ server: Server, destination: Workspace) -> Bool {
        ServerMoveSupport.requiresEnvironmentFallback(
            currentEnvironment: server.environment,
            destination: destination
        )
    }

    func canAssignServer(_ server: Server, to destination: Workspace) -> Bool {
        if server.workspaceId == destination.id {
            return true
        }
        return moveDestinationIDs(for: server).contains(destination.id)
    }

    func moveServer(
        _ server: Server,
        to destination: Workspace,
        preferredEnvironment: ServerEnvironment? = nil
    ) async throws -> Server {
        guard let refreshedDestination = workspace(withId: destination.id) else {
            throw VVTermError.moveNotAllowed(String(localized: "The destination workspace is no longer available."))
        }

        if let restriction = moveRestriction(for: server, destination: refreshedDestination) {
            throw restriction
        }

        let sourceWorkspace = workspace(withId: server.workspaceId)
        let resolvedEnvironment = resolvedEnvironment(
            for: server,
            destination: refreshedDestination,
            preferredEnvironment: preferredEnvironment
        )

        var updatedServer = server
        updatedServer.workspaceId = refreshedDestination.id
        updatedServer.environment = resolvedEnvironment

        try await updateServer(updatedServer)
        try await updateWorkspaceSelectionMetadataAfterMove(
            serverId: server.id,
            from: sourceWorkspace,
            to: refreshedDestination
        )

        return updatedServer
    }

    private func moveRestriction(for server: Server, destination: Workspace) -> VVTermError? {
        guard server.workspaceId != destination.id else { return nil }

        if moveDestinationIDs(for: server).contains(destination.id) {
            return nil
        }

        if !StoreManager.shared.isPro && isWorkspaceLocked(destination) {
            return VVTermError.proRequired(String(localized: "Upgrade to Pro to move servers into locked workspaces"))
        }

        return VVTermError.moveNotAllowed(String(localized: "This server can't be moved to that workspace right now."))
    }

    private func moveDestinationIDs(for server: Server) -> Set<UUID> {
        ServerAccessPolicy.moveDestinationIDs(
            isPro: StoreManager.shared.isPro,
            server: server,
            workspaces: workspaces
        )
    }

    private func updateWorkspaceSelectionMetadataAfterMove(
        serverId: UUID,
        from sourceWorkspace: Workspace?,
        to destinationWorkspace: Workspace
    ) async throws {
        if let sourceWorkspace,
           sourceWorkspace.id != destinationWorkspace.id,
           sourceWorkspace.lastSelectedServerId == serverId {
            var updatedSource = sourceWorkspace
            updatedSource.lastSelectedServerId = nil
            try await updateWorkspace(updatedSource)
        }

        if destinationWorkspace.lastSelectedServerId != serverId {
            var updatedDestination = destinationWorkspace
            updatedDestination.lastSelectedServerId = serverId
            try await updateWorkspace(updatedDestination)
        }
    }
}
