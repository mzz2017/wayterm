import Foundation
import Testing
@testable import Waterm

// Test Context:
// These tests protect the directory-load request identity owner used by the
// RemoteFiles browser. Directory listings are async SFTP work; stale results
// from an older tab request must not publish over a newer directory load, and
// tab teardown must clear only the affected tab. Update only when directory
// load staleness or tab-scoped cleanup intentionally changes.
struct RemoteFileDirectoryLoadRequestCoordinatorTests {
    @Test
    func newRequestSupersedesOnlyTheSameTab() {
        let firstTabID = UUID()
        let secondTabID = UUID()
        var coordinator = RemoteFileDirectoryLoadRequestCoordinator()

        // Given two tabs have current directory load requests.
        let staleFirstRequest = coordinator.beginRequest(for: firstTabID)
        let secondTabRequest = coordinator.beginRequest(for: secondTabID)

        // When the first tab starts a newer directory load.
        let currentFirstRequest = coordinator.beginRequest(for: firstTabID)

        // Then only the older first-tab request becomes stale.
        #expect(!coordinator.isCurrent(staleFirstRequest, for: firstTabID))
        #expect(coordinator.isCurrent(currentFirstRequest, for: firstTabID))
        #expect(coordinator.isCurrent(secondTabRequest, for: secondTabID))
    }

    @Test
    func clearingTabLeavesOtherTabRequestCurrent() {
        let firstTabID = UUID()
        let secondTabID = UUID()
        var coordinator = RemoteFileDirectoryLoadRequestCoordinator()

        // Given two tabs have current directory load requests.
        let firstRequest = coordinator.beginRequest(for: firstTabID)
        let secondRequest = coordinator.beginRequest(for: secondTabID)

        // When one tab is torn down.
        coordinator.clearRequest(for: firstTabID)

        // Then only that tab's directory request is cleared.
        #expect(!coordinator.isCurrent(firstRequest, for: firstTabID))
        #expect(coordinator.isCurrent(secondRequest, for: secondTabID))
    }
}
