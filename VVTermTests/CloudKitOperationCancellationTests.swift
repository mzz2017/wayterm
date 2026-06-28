import Foundation
import Testing
@testable import VVTerm

// Test Context:
// These tests protect CloudKit operation cancellation plumbing used by
// CloudKitManager's continuation-based CKOperation adapters. The fake operation
// avoids CloudKit network I/O; update only if CloudKitManager moves operation
// cancellation ownership to an equivalent Sync infrastructure helper.
struct CloudKitOperationCancellationTests {
    @Test
    func cancelAfterOperationRegistrationCancelsOperation() {
        let handle = CloudKitOperationCancellationHandle()
        let operation = FakeCloudKitOperation()

        // Given a CloudKit operation has been registered with the cancellation handle.
        handle.setOperation(operation)

        // When the parent sync task is cancelled.
        handle.cancel()

        // Then the underlying CloudKit operation is cancelled too.
        #expect(operation.cancelCallCount == 1, "Cancelling sync task should cancel the registered CKOperation.")
    }

    @Test
    func operationRegisteredAfterCancellationIsCancelledImmediately() {
        let handle = CloudKitOperationCancellationHandle()
        let operation = FakeCloudKitOperation()

        // Given cancellation wins the race before CloudKit operation registration.
        handle.cancel()

        // When the operation is later registered by the continuation setup.
        handle.setOperation(operation)

        // Then the operation is cancelled immediately and cannot escape cleanup.
        #expect(operation.cancelCallCount == 1, "Late-registered CKOperation should be cancelled immediately.")
    }
}

private final class FakeCloudKitOperation: CloudKitCancellableOperation {
    private(set) var cancelCallCount = 0

    func cancel() {
        cancelCallCount += 1
    }
}
