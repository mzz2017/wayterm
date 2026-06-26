import Foundation

extension ServerManager {
    func deleteServer(_ server: Server) async throws {
        await deletionTeardown(server)
        try await deleteCredentials(server.id)

        servers.removeAll { $0.id == server.id }
        let candidates = Self.knownHostRemovalCandidates(
            removedServers: [server],
            remainingServers: servers
        )
        await removeKnownHosts(for: candidates)
        enqueuePendingServerDelete(server)
        await persistLocalMutations(logMessage: "Deleted server: \(server.name)")
    }

    func deleteWorkspace(_ workspace: Workspace) async throws {
        // Delete all servers in workspace
        let workspaceServers = servers.filter { $0.workspaceId == workspace.id }
        for server in workspaceServers {
            try await deleteServer(server)
        }

        if pendingBootstrapWorkspaceID == workspace.id {
            pendingBootstrapWorkspaceID = nil
        }
        workspaces.removeAll { $0.id == workspace.id }
        enqueuePendingWorkspaceDelete(workspace)
        await persistLocalMutations(logMessage: "Deleted workspace: \(workspace.name)")
    }

    func deleteEnvironment(
        _ environment: ServerEnvironment,
        in workspace: Workspace
    ) async throws -> Workspace {
        try await deleteEnvironment(environment, in: workspace, fallback: .production)
    }

    func deleteEnvironment(
        _ environment: ServerEnvironment,
        in workspace: Workspace,
        fallback: ServerEnvironment
    ) async throws -> Workspace {
        var updatedWorkspace = workspace
        updatedWorkspace.environments.removeAll { $0.id == environment.id }
        if updatedWorkspace.lastSelectedEnvironmentId == environment.id {
            updatedWorkspace.lastSelectedEnvironmentId = fallback.id
        }

        try await updateWorkspace(updatedWorkspace)

        let serversToUpdate = servers.filter { $0.workspaceId == workspace.id && $0.environment.id == environment.id }
        for server in serversToUpdate {
            var updatedServer = server
            updatedServer.environment = fallback
            try await updateServer(updatedServer)
        }

        return updatedWorkspace
    }
}
