import Foundation

nonisolated enum ServerSidebarPolicy {
    static func environmentFilterIds(from storedValue: String) -> Set<UUID> {
        guard !storedValue.isEmpty else { return [] }
        return Set(storedValue.split(separator: ",").compactMap { UUID(uuidString: String($0)) })
    }

    static func storedEnvironmentFilters(from ids: Set<UUID>) -> String {
        ids.map(\.uuidString).sorted().joined(separator: ",")
    }

    static func allEnvironmentIds(in workspace: Workspace?) -> Set<UUID> {
        Set((workspace?.environments ?? []).map(\.id))
    }

    static func isEnvironmentFiltering(
        selectedEnvironmentIds: Set<UUID>,
        allEnvironmentIds: Set<UUID>
    ) -> Bool {
        !selectedEnvironmentIds.isEmpty && selectedEnvironmentIds != allEnvironmentIds
    }

    static func toggledEnvironmentIds(
        _ selectedEnvironmentIds: Set<UUID>,
        environmentId: UUID
    ) -> Set<UUID> {
        var ids = selectedEnvironmentIds
        if ids.contains(environmentId) {
            ids.remove(environmentId)
        } else {
            ids.insert(environmentId)
        }
        return ids
    }

    static func filteredServers(
        _ servers: [Server],
        selectedWorkspace: Workspace?,
        selectedEnvironmentIds: Set<UUID>,
        searchText: String
    ) -> [Server] {
        guard let workspace = selectedWorkspace else { return [] }

        let allEnvironmentIds = allEnvironmentIds(in: workspace)
        let isEnvironmentFiltering = isEnvironmentFiltering(
            selectedEnvironmentIds: selectedEnvironmentIds,
            allEnvironmentIds: allEnvironmentIds
        )
        let lowercasedSearchText = searchText.lowercased()

        return servers
            .filter { server in
                guard server.workspaceId == workspace.id else { return false }
                guard isEnvironmentFiltering else { return true }
                return selectedEnvironmentIds.contains(server.environment.id)
            }
            .filter { server in
                guard !lowercasedSearchText.isEmpty else { return true }
                return server.name.lowercased().contains(lowercasedSearchText)
                    || server.host.lowercased().contains(lowercasedSearchText)
            }
            .sorted { $0.name < $1.name }
    }

    static func serverCount(
        _ servers: [Server],
        selectedWorkspace: Workspace?
    ) -> Int {
        guard let workspace = selectedWorkspace else { return 0 }
        return servers.filter { $0.workspaceId == workspace.id }.count
    }

    static func shouldClearEnvironmentFiltersAfterSavingServer(
        originalServer: Server,
        savedServer: Server,
        selectedEnvironmentIds: Set<UUID>,
        allEnvironmentIds: Set<UUID>
    ) -> Bool {
        if originalServer.workspaceId != savedServer.workspaceId {
            return true
        }

        guard isEnvironmentFiltering(
            selectedEnvironmentIds: selectedEnvironmentIds,
            allEnvironmentIds: allEnvironmentIds
        ) else {
            return false
        }

        return !selectedEnvironmentIds.contains(savedServer.environment.id)
    }
}
