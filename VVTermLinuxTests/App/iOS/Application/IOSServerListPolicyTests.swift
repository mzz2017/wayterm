import XCTest
@testable import VVTermIOSApplicationLogic

final class IOSServerListPolicyTests: XCTestCase {
    private let workspaceA = UUID()
    private let workspaceB = UUID()
    private let production = UUID()
    private let staging = UUID()

    func testFilteredServersWithoutWorkspaceSearchesAllServersByNameOrHostPreservingOrder() {
        let servers = [
            server(name: "Database", host: "db.internal", workspaceId: workspaceB, environmentId: production),
            server(name: "Web", host: "web.example.com", workspaceId: workspaceA, environmentId: staging),
            server(name: "Cache", host: "redis.internal", workspaceId: workspaceA, environmentId: production)
        ]

        let result = IOSServerListPolicy.filteredServers(
            servers,
            selectedWorkspaceId: nil,
            selectedEnvironmentId: nil,
            searchText: "INTERNAL"
        )

        XCTAssertEqual(result.map(\.name), ["Database", "Cache"])
    }

    func testFilteredServersWithWorkspaceAndEnvironmentSortsByName() {
        let servers = [
            server(name: "Web", host: "web.example.com", workspaceId: workspaceA, environmentId: staging),
            server(name: "Cache", host: "redis.internal", workspaceId: workspaceA, environmentId: production),
            server(name: "Database", host: "db.internal", workspaceId: workspaceA, environmentId: production),
            server(name: "Other", host: "other.internal", workspaceId: workspaceB, environmentId: production)
        ]

        let result = IOSServerListPolicy.filteredServers(
            servers,
            selectedWorkspaceId: workspaceA,
            selectedEnvironmentId: production,
            searchText: ""
        )

        XCTAssertEqual(result.map(\.name), ["Cache", "Database"])
    }

    func testActiveConnectionsGroupByServerPreferSelectedSessionAndSortByTitle() {
        let alphaServer = UUID()
        let betaServer = UUID()
        let selectedBetaSession = UUID()
        let sessions = [
            IOSActiveConnectionSessionSnapshot(id: UUID(), serverId: betaServer, displayTitle: "Beta 1"),
            IOSActiveConnectionSessionSnapshot(id: selectedBetaSession, serverId: betaServer, displayTitle: "Beta 2"),
            IOSActiveConnectionSessionSnapshot(id: UUID(), serverId: alphaServer, displayTitle: "Alpha")
        ]

        let result = IOSServerListPolicy.activeConnections(
            from: sessions,
            selectedSessionId: selectedBetaSession
        )

        XCTAssertEqual(result.map(\.serverId), [alphaServer, betaServer])
        XCTAssertEqual(result.first(where: { $0.serverId == betaServer })?.representativeSessionId, selectedBetaSession)
        XCTAssertEqual(result.first(where: { $0.serverId == betaServer })?.tabCount, 2)
    }

    func testServerCountsByEnvironmentOnlyCountsSelectedWorkspace() {
        let servers = [
            server(name: "A", host: "a", workspaceId: workspaceA, environmentId: production),
            server(name: "B", host: "b", workspaceId: workspaceA, environmentId: production),
            server(name: "C", host: "c", workspaceId: workspaceA, environmentId: staging),
            server(name: "D", host: "d", workspaceId: workspaceB, environmentId: production)
        ]

        let result = IOSServerListPolicy.serverCountsByEnvironment(
            servers: servers,
            workspaceId: workspaceA,
            environmentIds: [production, staging]
        )

        XCTAssertEqual(result[production], 2)
        XCTAssertEqual(result[staging], 1)
    }

    private func server(
        id: UUID = UUID(),
        name: String,
        host: String,
        workspaceId: UUID,
        environmentId: UUID
    ) -> IOSServerListServerSnapshot {
        IOSServerListServerSnapshot(
            id: id,
            workspaceId: workspaceId,
            environmentId: environmentId,
            name: name,
            host: host
        )
    }
}
