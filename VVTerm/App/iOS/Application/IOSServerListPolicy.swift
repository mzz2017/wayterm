import Foundation

struct IOSServerListServerSnapshot: Equatable, Identifiable {
    let id: UUID
    let workspaceId: UUID
    let environmentId: UUID
    let name: String
    let host: String
}

struct IOSActiveConnectionSessionSnapshot: Equatable, Identifiable {
    let id: UUID
    let serverId: UUID
    let displayTitle: String
}

struct IOSActiveConnectionSnapshot: Equatable, Identifiable {
    let serverId: UUID
    let representativeSessionId: UUID
    let tabCount: Int
    let displayTitle: String

    var id: UUID { serverId }
}

enum IOSServerListPolicy {
    static let shouldForceNewConnectionFromServerList = true

    static func shouldReconnectActiveConnection(sessionHasLiveRuntime: Bool) -> Bool {
        !sessionHasLiveRuntime
    }

    static func filteredServers(
        _ servers: [IOSServerListServerSnapshot],
        selectedWorkspaceId: UUID?,
        selectedEnvironmentId: UUID?,
        searchText: String
    ) -> [IOSServerListServerSnapshot] {
        guard let selectedWorkspaceId else {
            return filterBySearch(servers, searchText: searchText)
        }

        var result = servers.filter { server in
            guard server.workspaceId == selectedWorkspaceId else { return false }
            guard let selectedEnvironmentId else { return true }
            return server.environmentId == selectedEnvironmentId
        }

        result = filterBySearch(result, searchText: searchText)
        return result.sorted { $0.name < $1.name }
    }

    static func activeConnections(
        from sessions: [IOSActiveConnectionSessionSnapshot],
        selectedSessionId: UUID?
    ) -> [IOSActiveConnectionSnapshot] {
        let grouped = Dictionary(grouping: sessions, by: \.serverId)
        return grouped.compactMap { serverId, sessions in
            guard let representative = representativeSession(
                for: sessions,
                selectedSessionId: selectedSessionId
            ) else {
                return nil
            }

            return IOSActiveConnectionSnapshot(
                serverId: serverId,
                representativeSessionId: representative.id,
                tabCount: sessions.count,
                displayTitle: representative.displayTitle
            )
        }
        .sorted { lhs, rhs in
            lhs.displayTitle.localizedCaseInsensitiveCompare(rhs.displayTitle) == .orderedAscending
        }
    }

    static func serverCountsByEnvironment(
        servers: [IOSServerListServerSnapshot],
        workspaceId: UUID?,
        environmentIds: [UUID]
    ) -> [UUID: Int] {
        guard let workspaceId else { return [:] }

        var counts = Dictionary(uniqueKeysWithValues: environmentIds.map { ($0, 0) })
        for server in servers where server.workspaceId == workspaceId {
            guard counts[server.environmentId] != nil else { continue }
            counts[server.environmentId, default: 0] += 1
        }
        return counts
    }

    private static func representativeSession(
        for sessions: [IOSActiveConnectionSessionSnapshot],
        selectedSessionId: UUID?
    ) -> IOSActiveConnectionSessionSnapshot? {
        if let selectedSessionId,
           let match = sessions.first(where: { $0.id == selectedSessionId }) {
            return match
        }
        return sessions.first
    }

    private static func filterBySearch(
        _ servers: [IOSServerListServerSnapshot],
        searchText: String
    ) -> [IOSServerListServerSnapshot] {
        guard !searchText.isEmpty else { return servers }

        let lowercased = searchText.lowercased()
        return servers.filter {
            $0.name.lowercased().contains(lowercased)
                || $0.host.lowercased().contains(lowercased)
        }
    }
}
