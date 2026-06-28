import XCTest
@testable import VVTermRemoteFilesApplicationLogic

// Test Context: protects remote-file tab title derivation used by iOS and
// shared connection tabs. Update these tests when tab title semantics change,
// not when the surrounding terminal UI moves.

final class RemoteFileTabTitlePolicyTests: XCTestCase {
    private let serverId = UUID()

    func testBaseTitleUsesLastVisitedPathBeforeTabPaths() {
        let tab = RemoteFileTabTitleInput(
            id: UUID(),
            serverId: serverId,
            seedPath: "/home/app",
            lastKnownPath: "/var/log",
            lastVisitedPath: "/opt/project"
        )

        XCTAssertEqual(RemoteFileTabTitlePolicy.baseTitle(for: tab, serverName: "Prod"), "project")
    }

    func testBaseTitleUsesServerNameForRootPath() {
        let tab = RemoteFileTabTitleInput(
            id: UUID(),
            serverId: serverId,
            seedPath: "/",
            lastKnownPath: nil,
            lastVisitedPath: nil
        )

        XCTAssertEqual(RemoteFileTabTitlePolicy.baseTitle(for: tab, serverName: "Prod"), "Prod")
    }

    func testDisplayedTitlesNumberDuplicateBaseTitlesInTabOrder() {
        let first = RemoteFileTabTitleInput(
            id: UUID(),
            serverId: serverId,
            seedPath: "/srv/app",
            lastKnownPath: nil,
            lastVisitedPath: nil
        )
        let second = RemoteFileTabTitleInput(
            id: UUID(),
            serverId: serverId,
            seedPath: "/opt/app",
            lastKnownPath: nil,
            lastVisitedPath: nil
        )
        let third = RemoteFileTabTitleInput(
            id: UUID(),
            serverId: serverId,
            seedPath: "/var/log",
            lastKnownPath: nil,
            lastVisitedPath: nil
        )

        let result = RemoteFileTabTitlePolicy.displayedTitles(
            for: [first, second, third],
            serverName: "Prod"
        )

        XCTAssertEqual(result[first.id], "app (1)")
        XCTAssertEqual(result[second.id], "app (2)")
        XCTAssertEqual(result[third.id], "log")
    }
}
