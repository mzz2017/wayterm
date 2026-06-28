import CloudKit
import Foundation

nonisolated protocol CloudKitCancellableOperation: AnyObject {
    func cancel()
}

extension CKOperation: CloudKitCancellableOperation {}

nonisolated final class CloudKitOperationCancellationHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var operation: (any CloudKitCancellableOperation)?
    private var isCancelled = false

    func setOperation(_ operation: any CloudKitCancellableOperation) {
        lock.lock()
        if isCancelled {
            lock.unlock()
            operation.cancel()
            return
        }

        self.operation = operation
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let operation = operation
        self.operation = nil
        lock.unlock()

        operation?.cancel()
    }
}
