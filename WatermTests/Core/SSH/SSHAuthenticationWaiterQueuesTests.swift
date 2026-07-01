import Foundation
import Testing
@testable import Waterm

// Test Context:
// These tests protect the keyed waiter queue used by SSHAuthenticationGate.
// Authentication is serialized per server/user key; canceling one queued waiter
// must not reorder or drop the remaining live waiters for that key. Update this
// file only when authentication waiter ordering intentionally changes.
struct SSHAuthenticationWaiterQueuesTests {
    @Test
    func removingMiddleWaiterPreservesFifoOrderForAuthenticationKey() {
        let key = "server:user"
        let firstID = UUID()
        let secondID = UUID()
        let thirdID = UUID()
        var queues = SSHAuthenticationWaiterQueues()

        // Given three authentication waiters queued for the same key.
        queues.enqueue(.init(id: firstID) { _ in }, for: key)
        queues.enqueue(.init(id: secondID) { _ in }, for: key)
        queues.enqueue(.init(id: thirdID) { _ in }, for: key)

        // When the middle waiter is canceled.
        let removed = queues.remove(id: secondID, for: key)

        // Then the canceled waiter is removed and remaining live waiters keep
        // their original FIFO order.
        #expect(removed?.id == secondID)
        #expect(queues.popFirst(for: key)?.id == firstID)
        #expect(queues.popFirst(for: key)?.id == thirdID)
        #expect(queues.popFirst(for: key) == nil)
    }
}
