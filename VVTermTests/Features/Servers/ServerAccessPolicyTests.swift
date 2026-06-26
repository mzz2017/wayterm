import XCTest
@testable import VVTerm

// Test Context:
// These tests protect free-tier and Pro access rules for servers and workspaces.
// They use in-memory fixtures only; update them when product limits or downgrade
// locking semantics intentionally change.

final class ServerAccessPolicyTests: XCTestCase {
    func testFreeTierUnlocksOldestServersByCreationDate() {
        let workspace = Workspace(name: "Main")
        let newest = makeServer(name: "newest", workspaceId: workspace.id, createdAt: Date(timeIntervalSince1970: 30))
        let oldest = makeServer(name: "oldest", workspaceId: workspace.id, createdAt: Date(timeIntervalSince1970: 10))
        let middle = makeServer(name: "middle", workspaceId: workspace.id, createdAt: Date(timeIntervalSince1970: 20))
        let locked = makeServer(name: "locked", workspaceId: workspace.id, createdAt: Date(timeIntervalSince1970: 40))

        let unlocked = ServerAccessPolicy.unlockedServerIds(
            isPro: false,
            servers: [newest, oldest, middle, locked]
        )

        XCTAssertEqual(unlocked, [oldest.id, middle.id, newest.id])
        XCTAssertTrue(ServerAccessPolicy.isServerLocked(locked, isPro: false, servers: [newest, oldest, middle, locked]))
    }

    func testFreeTierUnlocksWorkspacesByOrder() {
        let unlocked = Workspace(name: "Unlocked", order: 0)
        let locked = Workspace(name: "Locked", order: 1)

        let unlockedIDs = ServerAccessPolicy.unlockedWorkspaceIds(
            isPro: false,
            workspaces: [locked, unlocked]
        )

        XCTAssertEqual(unlockedIDs, [unlocked.id])
        XCTAssertTrue(ServerAccessPolicy.isWorkspaceLocked(locked, isPro: false, workspaces: [locked, unlocked]))
    }

    func testProUnlocksAllItemsAndAllowsCreation() {
        let workspaces = [
            Workspace(name: "First", order: 0),
            Workspace(name: "Second", order: 1)
        ]
        let servers = (0..<FreeTierLimits.maxServers + 1).map { index in
            makeServer(name: "Server \(index)", workspaceId: workspaces[0].id, createdAt: Date(timeIntervalSince1970: Double(index)))
        }

        XCTAssertTrue(ServerAccessPolicy.canAddServer(isPro: true, servers: servers))
        XCTAssertTrue(ServerAccessPolicy.canAddWorkspace(isPro: true, workspaces: workspaces))
        XCTAssertEqual(ServerAccessPolicy.unlockedServerIds(isPro: true, servers: servers), Set(servers.map(\.id)))
        XCTAssertEqual(ServerAccessPolicy.unlockedWorkspaceIds(isPro: true, workspaces: workspaces), Set(workspaces.map(\.id)))
        XCTAssertEqual(ServerAccessPolicy.lockedServersCount(isPro: true, servers: servers), 0)
        XCTAssertFalse(ServerAccessPolicy.hasLockedItems(isPro: true, servers: servers, workspaces: workspaces))
    }

    func testFreeTierCreationAndLockedCountsRespectLimits() {
        let workspace = Workspace(name: "Main")
        let serversAtLimit = (0..<FreeTierLimits.maxServers).map { index in
            makeServer(name: "Server \(index)", workspaceId: workspace.id, createdAt: Date(timeIntervalSince1970: Double(index)))
        }
        let overLimitServers = serversAtLimit + [
            makeServer(name: "Locked", workspaceId: workspace.id, createdAt: Date(timeIntervalSince1970: 100))
        ]
        let workspacesAtLimit = [workspace]
        let overLimitWorkspaces = workspacesAtLimit + [Workspace(name: "Locked", order: 1)]

        XCTAssertFalse(ServerAccessPolicy.canAddServer(isPro: false, servers: serversAtLimit))
        XCTAssertTrue(ServerAccessPolicy.canAddServer(isPro: false, servers: Array(serversAtLimit.dropLast())))
        XCTAssertFalse(ServerAccessPolicy.canAddWorkspace(isPro: false, workspaces: workspacesAtLimit))
        XCTAssertEqual(ServerAccessPolicy.lockedServersCount(isPro: false, servers: overLimitServers), 1)
        XCTAssertEqual(ServerAccessPolicy.lockedWorkspacesCount(isPro: false, workspaces: overLimitWorkspaces), 1)
        XCTAssertTrue(ServerAccessPolicy.hasLockedItems(isPro: false, servers: overLimitServers, workspaces: overLimitWorkspaces))
    }

    private func makeServer(name: String, workspaceId: UUID, createdAt: Date) -> Server {
        Server(
            workspaceId: workspaceId,
            name: name,
            host: "\(name).example.com",
            username: "vvterm",
            createdAt: createdAt,
            updatedAt: createdAt
        )
    }
}
