import Foundation
import Testing
@testable import VVTerm

// Test Context:
// These tests protect the queue owner used by RemoteConnectionLease while
// serializing borrowed/owned SSH client operations. Cancellation must remove
// only the matching waiter while preserving FIFO order for remaining live
// operations. Update this file only when RemoteConnectionLease intentionally
// changes how queued exclusive operations are ordered or canceled.
struct RemoteConnectionLeaseOperationWaiterQueueTests {
    @Test
    func removingMiddleWaiterPreservesFifoOrderForRemainingWaiters() {
        let firstID = UUID()
        let secondID = UUID()
        let thirdID = UUID()
        var queue = RemoteConnectionLeaseOperationWaiterQueue()

        // Given three queued lease operations waiting for exclusive client
        // access.
        queue.enqueue(.init(id: firstID) { _ in })
        queue.enqueue(.init(id: secondID) { _ in })
        queue.enqueue(.init(id: thirdID) { _ in })

        // When the middle waiter is canceled while the others remain live.
        let removed = queue.remove(id: secondID)

        // Then only the canceled waiter is removed and the remaining live
        // waiters keep their original FIFO order.
        #expect(removed?.id == secondID)
        #expect(queue.popFirst()?.id == firstID)
        #expect(queue.popFirst()?.id == thirdID)
        #expect(queue.isEmpty)
    }
}
