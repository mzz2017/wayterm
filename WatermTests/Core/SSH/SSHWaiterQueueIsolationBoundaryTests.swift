import Foundation
import Testing
@testable import Waterm

// Test Context:
// These boundary tests protect pure waiter queue helpers used by SSH auth and
// connection lease owners. The queues are actor-owned implementation details;
// they must not inherit default MainActor isolation, or actor methods that
// enqueue, resume, cancel, or drain waiters emit Swift concurrency warnings.
// Update only if these helpers intentionally become UI-owned state.
struct SSHWaiterQueueIsolationBoundaryTests {
    @Test
    func authenticationWaiterQueueHelpersRemainNonisolated() throws {
        let source = try source(
            at: sourceRoot().appendingPathComponent("Waterm/Core/SSH/SSHAuthenticationWaiterQueues.swift")
        )

        // Given SSHAuthenticationGate owns its waiter queues from an actor.
        #expect(
            source.contains("nonisolated struct SSHAuthenticationWaiter: Sendable"),
            "SSH authentication waiter callbacks should be usable from SSHAuthenticationGate without MainActor hops."
        )
        #expect(
            source.contains("nonisolated struct SSHAuthenticationWaiterQueues"),
            "SSHAuthenticationWaiterQueues should remain a pure actor-owned helper, not UI-isolated state."
        )
    }

    @Test
    func connectionLeaseWaiterQueueHelpersRemainNonisolated() throws {
        let source = try source(
            at: sourceRoot().appendingPathComponent(
                "Waterm/Core/SSH/RemoteConnectionLeaseOperationWaiterQueue.swift"
            )
        )

        // Given RemoteConnectionLeaseState owns its operation queue from an actor.
        #expect(
            source.contains("nonisolated struct RemoteConnectionLeaseOperationWaiter: Sendable"),
            "Lease operation waiter callbacks should be usable from RemoteConnectionLeaseState without MainActor hops."
        )
        #expect(
            source.contains("nonisolated struct RemoteConnectionLeaseOperationWaiterQueue"),
            "RemoteConnectionLease operation queues should remain pure actor-owned helpers, not UI-isolated state."
        )
    }

    private func source(at url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    private func sourceRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.lastPathComponent != "WatermTests" {
            let next = url.deletingLastPathComponent()
            if next.path == url.path {
                throw SourceRootError.notFound
            }
            url = next
        }
        return url.deletingLastPathComponent()
    }

    private enum SourceRootError: Error {
        case notFound
    }
}
