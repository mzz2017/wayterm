import Foundation
import Testing
@testable import Waterm

// Test Context:
// These tests protect RemoteFiles tab-opening policy shared by iOS terminal
// chrome and macOS connection tabs. The invariant is that duplicate-file-tab
// commands preserve the selected tab as source while seeding from its last
// visited path before falling back to terminal working directory.
// Update only when file-tab creation intentionally changes source/seed priority.

@MainActor
struct RemoteFileTabOpeningPolicyTests {
    @Test
    func newTabPlanDuplicatesSelectedFileTabAndUsesItsLastVisitedPath() {
        let serverId = UUID()
        let selectedTab = RemoteFileTab(serverId: serverId, seedPath: "/initial")

        // Given an existing file tab has a last visited path and the terminal
        // also has a working directory fallback.
        let plan = RemoteFileTabOpeningPolicy.newTabPlan(
            selectedFileTab: selectedTab,
            selectedFileTabLastVisitedPath: "/var/log",
            fallbackWorkingDirectory: "/home/user"
        )

        // Then opening a new file tab should duplicate the selected source tab
        // and seed from its latest browser path.
        #expect(plan.sourceTab == selectedTab)
        #expect(plan.seedPath == "/var/log")
    }

    @Test
    func newTabPlanDuplicatesSelectedFileTabWithWorkingDirectoryFallback() {
        let selectedTab = RemoteFileTab(serverId: UUID(), seedPath: "/initial")

        // Given the selected file tab has no browser path yet.
        let plan = RemoteFileTabOpeningPolicy.newTabPlan(
            selectedFileTab: selectedTab,
            selectedFileTabLastVisitedPath: nil,
            fallbackWorkingDirectory: "/srv/app"
        )

        // Then the selected tab is still duplicated, but the terminal working
        // directory becomes the seed path.
        #expect(plan.sourceTab == selectedTab)
        #expect(plan.seedPath == "/srv/app")
    }

    @Test
    func newTabPlanOpensFreshTabFromWorkingDirectoryWhenNoFileTabIsSelected() {
        // Given no file tab exists for the current server.
        let plan = RemoteFileTabOpeningPolicy.newTabPlan(
            selectedFileTab: nil,
            selectedFileTabLastVisitedPath: nil,
            fallbackWorkingDirectory: "/home/user"
        )

        // Then callers open a fresh tab seeded from the terminal context.
        #expect(plan.sourceTab == nil)
        #expect(plan.seedPath == "/home/user")
    }
}
