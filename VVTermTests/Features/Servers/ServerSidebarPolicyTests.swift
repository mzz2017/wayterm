import XCTest
@testable import VVTerm

// Test Context:
// ServerSidebarView presents workspace server navigation, but filtering, stable
// filter persistence, and post-save visibility rules belong to Servers
// application policy. These tests protect that boundary so sidebar UI remains a
// renderer and event sender rather than the owner of server list policy.

final class ServerSidebarPolicyTests: XCTestCase {
    func testEnvironmentFilterStorageRoundTripsValidIDsAndIgnoresInvalidTokens() {
        // Given stored filters with one invalid token.
        let firstId = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let secondId = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let storedValue = "\(secondId.uuidString),not-a-uuid,\(firstId.uuidString)"

        // When the policy decodes and re-encodes the filters.
        let ids = ServerSidebarPolicy.environmentFilterIds(from: storedValue)
        let encoded = ServerSidebarPolicy.storedEnvironmentFilters(from: ids)

        // Then invalid tokens are ignored and storage order is deterministic.
        XCTAssertEqual(ids, [firstId, secondId])
        XCTAssertEqual(
            encoded,
            [firstId.uuidString, secondId.uuidString].joined(separator: ","),
            "Persisted sidebar filters should not churn because Set iteration order changed."
        )
    }

    func testEnvironmentFilteringIsInactiveForEmptyOrAllSelectedFilters() {
        // Given a workspace with two available environments.
        let firstId = UUID()
        let secondId = UUID()
        let allEnvironmentIds: Set<UUID> = [firstId, secondId]

        // When the selected filters are empty or match every environment.
        // Then the sidebar should show all environments rather than apply a filter.
        XCTAssertFalse(
            ServerSidebarPolicy.isEnvironmentFiltering(
                selectedEnvironmentIds: [],
                allEnvironmentIds: allEnvironmentIds
            )
        )
        XCTAssertFalse(
            ServerSidebarPolicy.isEnvironmentFiltering(
                selectedEnvironmentIds: allEnvironmentIds,
                allEnvironmentIds: allEnvironmentIds
            )
        )
        XCTAssertTrue(
            ServerSidebarPolicy.isEnvironmentFiltering(
                selectedEnvironmentIds: [firstId],
                allEnvironmentIds: allEnvironmentIds
            )
        )
    }

    func testFilteredServersScopesToWorkspaceEnvironmentSearchAndSortsByName() {
        // Given servers spread across workspaces and environments.
        let workspace = makeWorkspace(id: UUID(), environments: [.production, .staging])
        let otherWorkspace = makeWorkspace(id: UUID(), environments: [.production])
        let servers = [
            makeServer(name: "zeta", host: "db.internal", workspaceId: workspace.id, environment: .production),
            makeServer(name: "Alpha", host: "api.internal", workspaceId: workspace.id, environment: .staging),
            makeServer(name: "beta", host: "bastion.internal", workspaceId: workspace.id, environment: .staging),
            makeServer(name: "Other", host: "api.internal", workspaceId: otherWorkspace.id, environment: .staging)
        ]

        // When the policy filters to staging servers matching the search text.
        let filtered = ServerSidebarPolicy.filteredServers(
            servers,
            selectedWorkspace: workspace,
            selectedEnvironmentIds: [ServerEnvironment.staging.id],
            searchText: "I"
        )

        // Then only matching servers in the selected workspace/environment remain in existing display order.
        XCTAssertEqual(filtered.map(\.name), ["Alpha", "beta"])
    }

    func testSavingServerClearsFiltersWhenServerMovesOrLeavesVisibleEnvironment() {
        // Given a filtered sidebar in production.
        let sourceWorkspaceId = UUID()
        let destinationWorkspaceId = UUID()
        let original = makeServer(
            name: "API",
            host: "api.internal",
            workspaceId: sourceWorkspaceId,
            environment: .production
        )
        let movedWorkspace = makeServer(
            name: "API",
            host: "api.internal",
            workspaceId: destinationWorkspaceId,
            environment: .production
        )
        let movedEnvironment = makeServer(
            name: "API",
            host: "api.internal",
            workspaceId: sourceWorkspaceId,
            environment: .staging
        )

        // When a save would otherwise hide the server.
        // Then filters clear so the saved server remains reachable.
        XCTAssertTrue(
            ServerSidebarPolicy.shouldClearEnvironmentFiltersAfterSavingServer(
                originalServer: original,
                savedServer: movedWorkspace,
                selectedEnvironmentIds: [ServerEnvironment.production.id],
                allEnvironmentIds: Set(ServerEnvironment.builtInEnvironments.map(\.id))
            )
        )
        XCTAssertTrue(
            ServerSidebarPolicy.shouldClearEnvironmentFiltersAfterSavingServer(
                originalServer: original,
                savedServer: movedEnvironment,
                selectedEnvironmentIds: [ServerEnvironment.production.id],
                allEnvironmentIds: Set(ServerEnvironment.builtInEnvironments.map(\.id))
            )
        )
    }

    func testSavingServerPreservesFiltersWhenSavedServerRemainsVisible() {
        // Given a filtered sidebar where the saved server still matches.
        let workspaceId = UUID()
        let original = makeServer(
            name: "API",
            host: "api.internal",
            workspaceId: workspaceId,
            environment: .production
        )
        let saved = makeServer(
            name: "API Updated",
            host: "api.internal",
            workspaceId: workspaceId,
            environment: .production
        )

        // When the server remains in the visible environment.
        // Then the current filter can be preserved.
        XCTAssertFalse(
            ServerSidebarPolicy.shouldClearEnvironmentFiltersAfterSavingServer(
                originalServer: original,
                savedServer: saved,
                selectedEnvironmentIds: [ServerEnvironment.production.id],
                allEnvironmentIds: Set(ServerEnvironment.builtInEnvironments.map(\.id))
            )
        )
    }

    private func makeWorkspace(
        id: UUID,
        environments: [ServerEnvironment]
    ) -> Workspace {
        Workspace(
            id: id,
            name: "Workspace",
            colorHex: "#007AFF",
            order: 0,
            environments: environments
        )
    }

    private func makeServer(
        name: String,
        host: String,
        workspaceId: UUID,
        environment: ServerEnvironment
    ) -> Server {
        Server(
            workspaceId: workspaceId,
            environment: environment,
            name: name,
            host: host,
            username: "root"
        )
    }
}
