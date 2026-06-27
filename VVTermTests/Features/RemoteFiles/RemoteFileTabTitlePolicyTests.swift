import Foundation
import Testing
@testable import VVTerm

// Test Context:
// These tests protect remote-file tab title policy after it moved out of
// platform terminal containers. The policy should derive compact, stable tab
// labels from the most recent remote path and disambiguate duplicate labels
// without asking SwiftUI view code to own path parsing or title collision rules.
// Update these tests only when RemoteFiles intentionally changes file-tab title
// behavior across iOS and macOS.
struct RemoteFileTabTitlePolicyTests {
    @Test
    func baseTitleFallsBackToServerNameWhenTabHasNoPath() {
        let tab = makeTab(seedPath: nil, lastKnownPath: nil, lastVisitedPath: nil)

        // Given a tab without any remote path history.
        let title = RemoteFileTabTitlePolicy.baseTitle(for: tab, serverName: "Tencent")

        // Then the visible title falls back to the server context.
        #expect(title == "Tencent")
    }

    @Test
    func baseTitleUsesMostRecentPathComponent() {
        let tab = makeTab(
            seedPath: "/var/log",
            lastKnownPath: "/srv/app",
            lastVisitedPath: "/home/deploy/releases"
        )

        // Given a tab with seed, known, and visited paths.
        let title = RemoteFileTabTitlePolicy.baseTitle(for: tab, serverName: "Tencent")

        // Then the most recent visited path determines the compact title.
        #expect(title == "releases")
    }

    @Test
    func baseTitleTreatsRootPathAsServerFallback() {
        let tab = makeTab(seedPath: "//", lastKnownPath: nil, lastVisitedPath: nil)

        // Given a tab whose only path normalizes to remote root.
        let title = RemoteFileTabTitlePolicy.baseTitle(for: tab, serverName: "Tencent")

        // Then root is not shown as a noisy tab label when server context exists.
        #expect(title == "Tencent")
    }

    @Test
    func displayedTitlesDisambiguatesDuplicateBaseTitlesInOrder() {
        let first = makeTab(id: UUID(), seedPath: "/srv/app")
        let second = makeTab(id: UUID(), seedPath: "/opt/app")
        let third = makeTab(id: UUID(), seedPath: "/var/log")

        // Given multiple tabs collapse to the same compact base label.
        let titles = RemoteFileTabTitlePolicy.displayedTitles(
            for: [first, second, third],
            serverName: "Tencent"
        )

        // Then duplicates receive stable ordinal suffixes while unique labels stay compact.
        #expect(titles[first.id] == "app (1)")
        #expect(titles[second.id] == "app (2)")
        #expect(titles[third.id] == "log")
    }

    private func makeTab(
        id: UUID = UUID(),
        seedPath: String?,
        lastKnownPath: String? = nil,
        lastVisitedPath: String? = nil
    ) -> RemoteFileTabTitleInput {
        RemoteFileTabTitleInput(
            id: id,
            serverId: UUID(),
            seedPath: seedPath,
            lastKnownPath: lastKnownPath,
            lastVisitedPath: lastVisitedPath
        )
    }
}
