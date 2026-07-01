import Foundation

nonisolated struct ServerKnownHostRemovalCandidate: Equatable, Sendable {
    let host: String
    let port: Int
}

nonisolated struct ServerSyncStateService {
    struct State: Equatable {
        let workspaces: [Workspace]
        let servers: [Server]
    }

    struct BackfillCandidates: Equatable {
        let workspaces: [Workspace]
        let servers: [Server]
    }

    struct OrphanRepair: Equatable {
        let original: Server
        let repaired: Server
    }

    struct OrphanRepairPlan: Equatable {
        let workspaces: [Workspace]
        let servers: [Server]
        let createdWorkspace: Workspace?
        let repairs: [OrphanRepair]

        var hasChanges: Bool {
            createdWorkspace != nil || !repairs.isEmpty
        }
    }

    func backfillCandidates(
        localWorkspaces: [Workspace],
        localServers: [Server],
        cloudWorkspaceIDs: Set<UUID>,
        cloudServerIDs: Set<UUID>,
        transientBootstrapWorkspaceID: UUID?
    ) -> BackfillCandidates {
        let missingWorkspaces = localWorkspaces.filter {
            !cloudWorkspaceIDs.contains($0.id) && $0.id != transientBootstrapWorkspaceID
        }

        let missingWorkspaceIDs = Set(missingWorkspaces.map(\.id))
        let missingServers = localServers.filter {
            !cloudServerIDs.contains($0.id) &&
                $0.workspaceId != transientBootstrapWorkspaceID &&
                (cloudWorkspaceIDs.contains($0.workspaceId) || missingWorkspaceIDs.contains($0.workspaceId))
        }

        return BackfillCandidates(workspaces: missingWorkspaces, servers: missingServers)
    }

    func fullFetchState(workspaces: [Workspace], servers: [Server]) -> State {
        State(
            workspaces: sortedWorkspaces(from: workspaceMap(from: workspaces)),
            servers: sortedServers(from: serverMap(from: servers))
        )
    }

    func upsertingWorkspaces(current: [Workspace], updates: [Workspace]) -> [Workspace] {
        var workspaceMap = workspaceMap(from: current)
        for workspace in updates {
            workspaceMap[workspace.id] = workspace
        }
        return sortedWorkspaces(from: workspaceMap)
    }

    func upsertingServers(current: [Server], updates: [Server]) -> [Server] {
        var serverMap = serverMap(from: current)
        for server in updates {
            serverMap[server.id] = server
        }
        return sortedServers(from: serverMap)
    }

    func workspaceForOrphanRepair(
        existingWorkspaces: [Workspace],
        servers: [Server],
        fallbackWorkspace: Workspace
    ) -> Workspace? {
        let workspaceIDs = Set(existingWorkspaces.map(\.id))
        guard servers.contains(where: { !workspaceIDs.contains($0.workspaceId) }) else {
            return nil
        }

        return existingWorkspaces.first ?? fallbackWorkspace
    }

    func orphanRepairPlan(
        workspaces existingWorkspaces: [Workspace],
        servers existingServers: [Server],
        fallbackWorkspace: Workspace,
        updatedAt: Date
    ) -> OrphanRepairPlan {
        guard let repairWorkspace = workspaceForOrphanRepair(
            existingWorkspaces: existingWorkspaces,
            servers: existingServers,
            fallbackWorkspace: fallbackWorkspace
        ) else {
            return OrphanRepairPlan(
                workspaces: existingWorkspaces,
                servers: existingServers,
                createdWorkspace: nil,
                repairs: []
            )
        }

        let createdWorkspace = existingWorkspaces.isEmpty ? repairWorkspace : nil
        let repairedWorkspaces = createdWorkspace.map { [$0] } ?? existingWorkspaces
        let validWorkspaceIDs = Set(repairedWorkspaces.map(\.id))

        var repairs: [OrphanRepair] = []
        let repairedServers = existingServers.map { server in
            guard !validWorkspaceIDs.contains(server.workspaceId) else {
                return server
            }

            var repaired = server
            repaired.workspaceId = repairWorkspace.id
            repaired.updatedAt = updatedAt
            repairs.append(OrphanRepair(original: server, repaired: repaired))
            return repaired
        }

        return OrphanRepairPlan(
            workspaces: repairedWorkspaces,
            servers: repairedServers,
            createdWorkspace: createdWorkspace,
            repairs: repairs
        )
    }

    func knownHostRemovalCandidates(
        removedServers: [Server],
        remainingServers: [Server]
    ) -> [ServerKnownHostRemovalCandidate] {
        var candidates: [ServerKnownHostRemovalCandidate] = []
        var seen = Set<String>()

        for server in removedServers {
            let isStillUsed = remainingServers.contains {
                $0.host == server.host && $0.port == server.port
            }
            guard !isStillUsed else { continue }

            let key = "\(server.host):\(server.port)"
            guard seen.insert(key).inserted else { continue }
            candidates.append(ServerKnownHostRemovalCandidate(host: server.host, port: server.port))
        }

        return candidates
    }

    private func workspaceMap(from workspaces: [Workspace]) -> [UUID: Workspace] {
        var workspaceMap: [UUID: Workspace] = [:]
        for workspace in workspaces {
            workspaceMap[workspace.id] = workspace
        }
        return workspaceMap
    }

    private func serverMap(from servers: [Server]) -> [UUID: Server] {
        var serverMap: [UUID: Server] = [:]
        for server in servers {
            serverMap[server.id] = server
        }
        return serverMap
    }

    private func sortedWorkspaces(from workspaceMap: [UUID: Workspace]) -> [Workspace] {
        Array(workspaceMap.values).sorted { $0.order < $1.order }
    }

    private func sortedServers(from serverMap: [UUID: Server]) -> [Server] {
        Array(serverMap.values).sorted { $0.name < $1.name }
    }
}
