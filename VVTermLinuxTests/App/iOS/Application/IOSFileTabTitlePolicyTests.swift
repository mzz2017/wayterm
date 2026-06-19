import XCTest
@testable import VVTermIOSApplicationLogic

final class IOSFileTabTitlePolicyTests: XCTestCase {
    private let serverId = UUID()

    func testBaseTitleUsesLastVisitedPathBeforeTabPaths() {
        let tab = IOSFileTabTitleInput(
            id: UUID(),
            serverId: serverId,
            seedPath: "/home/app",
            lastKnownPath: "/var/log",
            lastVisitedPath: "/opt/project"
        )

        XCTAssertEqual(IOSFileTabTitlePolicy.baseTitle(for: tab, serverName: "Prod"), "project")
    }

    func testBaseTitleUsesServerNameForRootPath() {
        let tab = IOSFileTabTitleInput(
            id: UUID(),
            serverId: serverId,
            seedPath: "/",
            lastKnownPath: nil,
            lastVisitedPath: nil
        )

        XCTAssertEqual(IOSFileTabTitlePolicy.baseTitle(for: tab, serverName: "Prod"), "Prod")
    }

    func testDisplayedTitlesNumberDuplicateBaseTitlesInTabOrder() {
        let first = IOSFileTabTitleInput(
            id: UUID(),
            serverId: serverId,
            seedPath: "/srv/app",
            lastKnownPath: nil,
            lastVisitedPath: nil
        )
        let second = IOSFileTabTitleInput(
            id: UUID(),
            serverId: serverId,
            seedPath: "/opt/app",
            lastKnownPath: nil,
            lastVisitedPath: nil
        )
        let third = IOSFileTabTitleInput(
            id: UUID(),
            serverId: serverId,
            seedPath: "/var/log",
            lastKnownPath: nil,
            lastVisitedPath: nil
        )

        let result = IOSFileTabTitlePolicy.displayedTitles(
            for: [first, second, third],
            serverName: "Prod"
        )

        XCTAssertEqual(result[first.id], "app (1)")
        XCTAssertEqual(result[second.id], "app (2)")
        XCTAssertEqual(result[third.id], "log")
    }
}
