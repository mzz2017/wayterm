import Foundation
import Testing
@testable import VVTerm

// Test Context:
// These tests protect the Stats visibility trigger key used by SwiftUI to send
// collection start/stop intent. The key is pure value policy: it must change
// when the visible borrowed SSH client changes, while avoiding hidden-state
// churn. Fakes do not perform network or SSH work.
@MainActor
struct ServerStatsCollectionTaskKeyTests {
    @Test
    func visibleTaskKeyChangesWhenBorrowedLeaseClientChanges() {
        let serverId = UUID()
        let firstClient = StatsTaskKeyClient()
        let secondClient = StatsTaskKeyClient()
        let firstLease = RemoteConnectionLease(client: firstClient, ownership: .borrowed)
        let sameClientLease = RemoteConnectionLease(client: firstClient, ownership: .borrowed)
        let secondLease = RemoteConnectionLease(client: secondClient, ownership: .borrowed)

        // Given Stats is visible for one server and SwiftUI recomputes the key
        // from whichever terminal SSH client is currently visible.
        let firstKey = ServerStatsCollectionTaskKey(
            serverId: serverId,
            isVisible: true,
            borrowedLease: firstLease
        )
        let sameClientKey = ServerStatsCollectionTaskKey(
            serverId: serverId,
            isVisible: true,
            borrowedLease: sameClientLease
        )
        let secondKey = ServerStatsCollectionTaskKey(
            serverId: serverId,
            isVisible: true,
            borrowedLease: secondLease
        )

        // Then another borrowed lease for the same stable client should not
        // churn collection, but a different visible client must trigger a
        // replacement start intent.
        #expect(firstKey == sameClientKey)
        #expect(
            firstKey != secondKey,
            "Stats visibility key must change when the visible borrowed SSH client changes."
        )
    }

    @Test
    func hiddenTaskKeyIgnoresBorrowedLeaseClientChanges() {
        let serverId = UUID()
        let firstLease = RemoteConnectionLease(client: StatsTaskKeyClient(), ownership: .borrowed)
        let secondLease = RemoteConnectionLease(client: StatsTaskKeyClient(), ownership: .borrowed)

        // Given Stats is hidden.
        let firstHiddenKey = ServerStatsCollectionTaskKey(
            serverId: serverId,
            isVisible: false,
            borrowedLease: firstLease
        )
        let secondHiddenKey = ServerStatsCollectionTaskKey(
            serverId: serverId,
            isVisible: false,
            borrowedLease: secondLease
        )

        // Then hidden UI should not keep sending stop intent just because the
        // terminal selection changed behind it.
        #expect(firstHiddenKey == secondHiddenKey)
    }
}

private actor StatsTaskKeyClient: RemoteConnectionLeaseClient {
    func disconnect() async {}

    func execute(_ command: String, timeout: Duration?) async throws -> String {
        ""
    }

    func upload(
        _ data: Data,
        to remotePath: String,
        permissions: Int32,
        strategy: SSHUploadStrategy
    ) async throws {}

    func remoteEnvironment(forceRefresh: Bool) async -> RemoteEnvironment {
        .fallbackPOSIX
    }

    func remoteTerminalType(forceRefresh: Bool) async -> RemoteTerminalType {
        .xterm256Color
    }
}
