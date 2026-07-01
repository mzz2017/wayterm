import Foundation
import Testing
@testable import Waterm

// Test Context:
// These tests protect the shared NotificationCenter observer-token owner used
// by long-lived stores and runtime adapters. NotificationCenter returns
// NSObjectProtocol tokens that are not Sendable under Swift 6 checking, so
// owners should move token storage into this idempotent lifecycle primitive
// instead of reading token properties directly from nonisolated deinit paths.
// Update these tests only if observer token ownership intentionally moves to a
// different shared lifecycle primitive.

struct NotificationObserverTokensTests {
    @Test
    func invalidateAllRemovesCallbacksAndIsIdempotent() {
        let notificationCenter = NotificationCenter()
        let notificationName = Notification.Name("NotificationObserverTokensTests.observer")
        let observerTokens = NotificationObserverTokens(notificationCenter: notificationCenter)
        let receipts = NotificationReceiptCounter()

        // Given a NotificationCenter observer token owned by the shared
        // lifecycle primitive.
        let token = notificationCenter.addObserver(forName: notificationName, object: nil, queue: nil) { _ in
            receipts.record()
        }
        observerTokens.append(token)

        // When callbacks arrive before and after repeated invalidation.
        notificationCenter.post(name: notificationName, object: nil)
        observerTokens.invalidateAll()
        observerTokens.invalidateAll()
        notificationCenter.post(name: notificationName, object: nil)

        // Then the observer is removed once and no late callback is delivered.
        #expect(receipts.count == 1)
    }
}

private final class NotificationReceiptCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var receivedCount = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return receivedCount
    }

    func record() {
        lock.lock()
        receivedCount += 1
        lock.unlock()
    }
}
